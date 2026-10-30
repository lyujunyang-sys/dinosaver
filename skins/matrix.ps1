# ============================================================
#  皮肤：字母雨（黑客帝国）
#  1080p 满屏是两千六百多个字。一个字一次 DrawImage 的话，光 GDI+ 的调用开销
#  （每次约 10µs）就是 25ms，一帧预算只有 30ms——所以不走 GDI+ 逐字画：
#  自己拿一个 int[] 当像素缓冲把整帧拼好，再整屏送一次（实测 3.75ms）。
#  字模是「绿字已经叠在黑底上」的不透明小块，格子又互不重叠，
#  所以合成就是纯粹的行拷贝，不用做 alpha 混合。
#  编译是懒加载的——没选这张皮肤就不花这 1 秒。
# ============================================================

$MatrixCSharp = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class MatrixRain {
    private int W, H, cw, ch, cols, rows, levels, nChars;
    private int[][] tiles;         // [字*(档数+1)+档]，每块是 cw*ch 的不透明像素
    private int[] buf;             // 整帧像素，钉住不动
    private int[] blackRow;        // 一行不透明黑，用来铺底
    private GCHandle hbuf;
    private Bitmap frame;          // 直接盖在 buf 上的位图，不用每帧上传
    private Random rnd;
    private double[] head, speed;  // head 是「队头在第几行」，可以是小数也可以是负的（还没进屏幕）
    private int[] len;
    private int[] glyphs;          // cols*rows，每个格子当前显示哪个字

    public MatrixRain(int w, int h, int cellH, int seed) {
        W = w; H = h; ch = cellH;
        cw = (int)Math.Round(cellH * 0.62);
        if (cw < 6) cw = 6;
        cols = W / cw + 1;
        rows = H / ch + 1;
        levels = 10;
        rnd = new Random(seed);
        BuildAtlas();
        buf = new int[W * H];
        blackRow = new int[W];
        for (int i = 0; i < W; i++) blackRow[i] = unchecked((int)0xFF000000);
        hbuf = GCHandle.Alloc(buf, GCHandleType.Pinned);
        frame = new Bitmap(W, H, W * 4, PixelFormat.Format32bppPArgb, hbuf.AddrOfPinnedObject());
        head = new double[cols]; speed = new double[cols]; len = new int[cols];
        glyphs = new int[cols * rows];
        for (int i = 0; i < glyphs.Length; i++) glyphs[i] = rnd.Next(nChars);
        for (int c = 0; c < cols; c++) ResetCol(c, true);
    }

    // 半角片假名才是那个味道。中文 Windows 上 SimSun/雅黑 也覆盖这段码位，
    // 一个都找不到就退回纯 ASCII，宁可少几个字也不要满屏豆腐块。
    private string PickFamily() {
        string[] want = { "MS Gothic", "SimSun", "Microsoft YaHei", "Consolas" };
        foreach (string f in want) {
            try { using (var ff = new FontFamily(f)) { return f; } } catch { }
        }
        return "Courier New";
    }

    private void BuildAtlas() {
        string fam = PickFamily();
        var list = new List<char>();
        if (fam != "Consolas" && fam != "Courier New")
            for (int c = 0xFF66; c <= 0xFF9D; c++) list.Add((char)c);   // 半角片假名
        for (char c = '0'; c <= '9'; c++) list.Add(c);
        foreach (char c in "ABCDEFGHIJKLMNPQRSTUVWXYZ:.=*+-<>|") list.Add(c);
        nChars = list.Count;

        Color[] pal = new Color[levels + 1];
        pal[0] = Color.FromArgb(255, 225, 255, 235);     // 队头：几乎是白的
        for (int l = 1; l <= levels; l++) {
            double t = (double)(l - 1) / (levels - 1);   // 0 = 紧跟队头，1 = 尾巴
            double k = Math.Pow(1.0 - t, 1.6);
            pal[l] = Color.FromArgb((int)(60 + 195 * k), (int)(30 * k), (int)(60 + 195 * k), (int)(25 + 65 * k));
        }

        // 字模烤成不透明小块：绿字直接画在黑底上，取出来就是一块可以整片拷贝的像素。
        // 背景本来就是黑的，格子又互不重叠，所以运行时一次 alpha 混合都不用做。
        tiles = new int[nChars * (levels + 1)][];
        using (Font f = new Font(fam, ch * 0.86f, FontStyle.Regular, GraphicsUnit.Pixel))
        using (Bitmap b = new Bitmap(cw, ch, PixelFormat.Format32bppPArgb))
        using (Graphics g = Graphics.FromImage(b)) {
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            for (int i = 0; i < nChars; i++) {
                string s = list[i].ToString();
                SizeF sz = g.MeasureString(s, f);
                for (int l = 0; l <= levels; l++) {
                    g.Clear(Color.Black);
                    using (var br = new SolidBrush(pal[l]))
                        g.DrawString(s, f, br, (cw - sz.Width) / 2f, (ch - sz.Height) / 2f);
                    int[] t = new int[cw * ch];
                    BitmapData d = b.LockBits(new Rectangle(0, 0, cw, ch), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
                    for (int y = 0; y < ch; y++)
                        Marshal.Copy((IntPtr)(d.Scan0.ToInt64() + y * d.Stride), t, y * cw, cw);
                    b.UnlockBits(d);
                    tiles[i * (levels + 1) + l] = t;
                }
            }
        }
    }

    private void ResetCol(int c, bool init) {
        // 开场让每列错开落下，不然第一帧是一条直线
        head[c]  = init ? -rnd.Next(0, rows * 2) : -rnd.Next(0, rows / 2 + 1);
        speed[c] = 0.22 + rnd.NextDouble() * 0.85;       // 行/帧
        len[c]   = 8 + rnd.Next(Math.Max(4, rows / 2));
    }

    public void Step() {
        for (int c = 0; c < cols; c++) {
            int before = (int)Math.Floor(head[c]);
            head[c] += speed[c];
            int after = (int)Math.Floor(head[c]);
            // 队头每跨进一个新格子就现摇一个字
            for (int r = before + 1; r <= after; r++)
                if (r >= 0 && r < rows) glyphs[c * rows + r] = rnd.Next(nChars);
            if (head[c] - len[c] > rows) ResetCol(c, false);
        }
        // 已经落下的字偶尔翻个面，才像在「流」而不是在平移
        int mut = glyphs.Length / 90 + 1;
        for (int i = 0; i < mut; i++) glyphs[rnd.Next(glyphs.Length)] = rnd.Next(nChars);
    }

    public void Draw(Graphics g) {
        // 铺黑底。用「一行黑 × 拷 H 次」而不是 Array.Clear：
        // Array.Clear 填出来的是 alpha=0 的透明黑，后面怎么合成就要看目标表面的脸色；
        // 这里直接铺不透明黑（0xFF000000），语义上没有含糊的余地。
        for (int y = 0; y < H; y++) Array.Copy(blackRow, 0, buf, y * W, W);
        for (int c = 0; c < cols; c++) {
            int hc = (int)Math.Floor(head[c]);
            int L  = len[c];
            int x  = c * cw;
            int wEff = Math.Min(cw, W - x);       // 最右边那列可能只露出半格
            if (wEff <= 0) continue;
            for (int i = 0; i < L; i++) {
                int r = hc - i;
                if (r < 0) break;                 // i 越大 r 越小，出了界后面只会更界外
                if (r >= rows) continue;          // 队头还在屏幕下面
                int lv;
                if (i == 0) lv = 0;
                else { lv = 1 + (int)((double)(i - 1) / (L - 1) * (levels - 1)); if (lv > levels) lv = levels; }
                int[] t = tiles[glyphs[c * rows + r] * (levels + 1) + lv];
                int y0 = r * ch;
                int hEff = Math.Min(ch, H - y0);
                for (int ty = 0; ty < hEff; ty++)
                    Array.Copy(t, ty * cw, buf, (y0 + ty) * W + x, wEff);
            }
        }
        // 整屏送一次。SourceCopy：不做混合，直接覆盖，比 SourceOver 省一道工序
        CompositingMode old = g.CompositingMode;
        g.CompositingMode = CompositingMode.SourceCopy;
        g.DrawImageUnscaled(frame, 0, 0);
        g.CompositingMode = old;
    }
}
'@

@{
    Id    = 'matrix'
    Title = '字母雨（黑客帝国）'
    Desc  = "满屏半角片假名往下淌，队头一个白字拖一条由亮到暗的绿尾巴。`r`n每列速度、长度、起点都不一样，落到底自动重投。"

    Init = {
        param($ctx)
        if (-not ('MatrixRain' -as [type])) {
            Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $MatrixCSharp
        }
        $cell = [Math]::Max(16, [int]($ctx.Scale * 4))
        $r = New-Object MatrixRain -ArgumentList $ctx.W, $ctx.H, $cell, $ctx.Rnd.Next()
        @{
            r  = $r
            bg = [System.Drawing.Color]::Black
            fg = [System.Drawing.Color]::FromArgb(0, 200, 90)
        }
    }

    Update = { param($ctx, $st) $st.r.Step() }
    Draw   = { param($ctx, $st, $g) $st.r.Draw($g) }
    Theme  = { param($ctx, $st) @{ Bg = $st.bg; Fg = $st.fg } }
}
