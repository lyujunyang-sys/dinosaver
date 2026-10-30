# ============================================================
#  皮肤：柏林噪声流场
#  屏幕底下铺着一张看不见的「风场」：每个点的风向由三维柏林噪声决定
#  （第三维是时间，所以风场自己会慢慢变形）。几千个粒子顺着风走，
#  拖出渐隐的尾巴——看起来像烟、像洋流、像丝绸里的纹路。
#  几千条尾巴用 GDI+ 逐段画是不可能的（每次调用约 10µs），
#  所以跟字母雨一样：自己拿钉住的 int[] 当像素缓冲，
#  自己写画线和叠加混合，整帧拼好再送一次。
# ============================================================

$FlowCSharp = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class FlowField {
    private int W, H, N, K;
    private int[] buf, bgRow;
    private GCHandle hbuf;
    private Bitmap frame;
    private Random rnd;
    private float[] px, py, hx, hy;
    private int[] life;
    private byte[] cr, cg, cb;
    private int hw;                       // 历史环形缓冲写到第几帧
    private int[] perm = new int[512];
    private double tnoise, freq, tspd;
    private int[] iw1, iw0, wt;           // 尾巴每一档的环形下标和亮度
    private float speed;
    private const int BG = unchecked((int)0xFF08090F);

    public FlowField(int w, int h, int n, int seed) {
        W = w; H = h; N = n; K = 16;
        rnd = new Random(seed);
        buf = new int[W * H];
        bgRow = new int[W];
        for (int i = 0; i < W; i++) bgRow[i] = BG;
        hbuf = GCHandle.Alloc(buf, GCHandleType.Pinned);
        frame = new Bitmap(W, H, W * 4, PixelFormat.Format32bppPArgb, hbuf.AddrOfPinnedObject());

        int[] p = new int[256];
        for (int i = 0; i < 256; i++) p[i] = i;
        for (int i = 255; i > 0; i--) { int j = rnd.Next(i + 1); int t = p[i]; p[i] = p[j]; p[j] = t; }
        for (int i = 0; i < 512; i++) perm[i] = p[i & 255];

        freq  = 2.6 / Math.Min(W, H);      // 风场花纹大概四分之一屏那么大
        tspd  = 0.0035;                    // 风场变形速度
        speed = (float)(Math.Min(W, H) / 470.0);

        px = new float[N]; py = new float[N]; life = new int[N];
        hx = new float[N * K]; hy = new float[N * K];
        cr = new byte[N]; cg = new byte[N]; cb = new byte[N];
        iw1 = new int[K]; iw0 = new int[K]; wt = new int[K];
        for (int i = 0; i < N; i++) Respawn(i, true);
    }

    // ---------- 柏林噪声（Ken Perlin 改进版，三维）----------
    private static double Fade(double t) { return t * t * t * (t * (t * 6 - 15) + 10); }
    private static double Lerp(double a, double b, double t) { return a + t * (b - a); }
    private static double Grad(int hash, double x, double y, double z) {
        int h = hash & 15;
        double u = h < 8 ? x : y;
        double v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
    }
    private double Noise(double x, double y, double z) {
        int X = (int)Math.Floor(x) & 255, Y = (int)Math.Floor(y) & 255, Z = (int)Math.Floor(z) & 255;
        x -= Math.Floor(x); y -= Math.Floor(y); z -= Math.Floor(z);
        double u = Fade(x), v = Fade(y), w = Fade(z);
        int A = perm[X] + Y, AA = perm[A & 255] + Z, AB = perm[(A + 1) & 255] + Z;
        int B = perm[(X + 1) & 255] + Y, BA = perm[B & 255] + Z, BB = perm[(B + 1) & 255] + Z;
        return Lerp(Lerp(Lerp(Grad(perm[AA & 255], x, y, z), Grad(perm[BA & 255], x - 1, y, z), u),
                         Lerp(Grad(perm[AB & 255], x, y - 1, z), Grad(perm[BB & 255], x - 1, y - 1, z), u), v),
                    Lerp(Lerp(Grad(perm[(AA + 1) & 255], x, y, z - 1), Grad(perm[(BA + 1) & 255], x - 1, y, z - 1), u),
                         Lerp(Grad(perm[(AB + 1) & 255], x, y - 1, z - 1), Grad(perm[(BB + 1) & 255], x - 1, y - 1, z - 1), u), v), w);
    }

    // 颜色按粒子出生点的噪声取：同一股气流里的粒子颜色是接近的，
    // 所以画面会分出一条条颜色不同的「流」，而不是一锅乱七八糟的彩色。
    private void PickColor(int i, double n) {
        double t = (n + 1) * 0.5; if (t < 0) t = 0; if (t > 1) t = 1;
        double r, g, b;
        if (rnd.Next(100) < 8) { r = 255; g = 175; b = 80; }          // 少量暖色点缀
        else if (t < 0.5) { double u = t / 0.5; r = 30 + 20 * u; g = 70 + 130 * u; b = 190 + 40 * u; }
        else { double u = (t - 0.5) / 0.5; r = 50 + 160 * u; g = 200 + 40 * u; b = 230 + 25 * u; }
        cr[i] = (byte)r; cg[i] = (byte)g; cb[i] = (byte)b;
    }

    private void Respawn(int i, bool init) {
        px[i] = (float)(rnd.NextDouble() * W);
        py[i] = (float)(rnd.NextDouble() * H);
        life[i] = 140 + rnd.Next(320);
        PickColor(i, Noise(px[i] * freq, py[i] * freq, tnoise));
        // 整条历史填成同一个点，免得重生时从旧位置拉出一道横贯屏幕的线
        for (int k = 0; k < K; k++) { hx[i * K + k] = px[i]; hy[i * K + k] = py[i]; }
    }

    public void Step() {
        tnoise += tspd;
        int slot = hw % K;
        for (int i = 0; i < N; i++) {
            double ang = Noise(px[i] * freq, py[i] * freq, tnoise) * Math.PI * 3.2;
            px[i] += (float)(Math.Cos(ang) * speed);
            py[i] += (float)(Math.Sin(ang) * speed);
            life[i]--;
            if (life[i] <= 0 || px[i] < -20 || px[i] > W + 20 || py[i] < -20 || py[i] > H + 20) {
                Respawn(i, false);
            }
            hx[i * K + slot] = px[i]; hy[i * K + slot] = py[i];
        }
        hw++;
    }

    // 加色混合往缓冲里点一个像素
    private void Plot(int x, int y, int r, int g, int b) {
        if (x < 0 || x >= W || y < 0 || y >= H) return;
        int idx = y * W + x, p = buf[idx];
        int rr = ((p >> 16) & 0xFF) + r; if (rr > 255) rr = 255;
        int gg = ((p >> 8) & 0xFF) + g;  if (gg > 255) gg = 255;
        int bb = (p & 0xFF) + b;         if (bb > 255) bb = 255;
        buf[idx] = unchecked((int)0xFF000000) | (rr << 16) | (gg << 8) | bb;
    }

    private void Line(float x0, float y0, float x1, float y1, int r, int g, int b) {
        float dx = x1 - x0, dy = y1 - y0;
        int n = (int)Math.Max(Math.Abs(dx), Math.Abs(dy));
        if (n > 40) return;                 // 异常长的一段（重生残留）直接不画
        if (n <= 0) { Plot((int)x0, (int)y0, r, g, b); return; }
        float sx = dx / n, sy = dy / n;
        float x = x0, y = y0;
        for (int i = 0; i <= n; i++) { Plot((int)x, (int)y, r, g, b); x += sx; y += sy; }
    }

    public void Draw(Graphics g) {
        for (int y = 0; y < H; y++) Array.Copy(bgRow, 0, buf, y * W, W);
        // 每一档的环形下标和亮度跟「哪个粒子」无关，先算好：
        // 内层循环要跑十万次，取模和除法留在里面就是白送十几毫秒
        int have = Math.Min(hw, K);
        for (int k = 1; k < have; k++) {
            iw1[k] = (hw - k + K * 2) % K;
            iw0[k] = (hw - k - 1 + K * 2) % K;
            double f = 1.0 - (double)k / have;      // 越老越暗
            wt[k] = (int)(f * f * 235);
        }
        for (int i = 0; i < N; i++) {
            int bi = i * K;
            int r0 = cr[i], g0 = cg[i], b0 = cb[i];
            for (int k = 1; k < have; k++) {
                int w = wt[k];
                if (w <= 2) continue;
                Line(hx[bi + iw0[k]], hy[bi + iw0[k]], hx[bi + iw1[k]], hy[bi + iw1[k]],
                     r0 * w / 255, g0 * w / 255, b0 * w / 255);
            }
        }
        CompositingMode old = g.CompositingMode;
        g.CompositingMode = CompositingMode.SourceCopy;
        g.DrawImageUnscaled(frame, 0, 0);
        g.CompositingMode = old;
    }
}
'@

@{
    Id    = 'flow'
    Title = '柏林噪声流场'
    Desc  = "屏幕底下铺着一张看不见的风场，风向由三维柏林噪声决定，第三维是时间，`r`n所以风场自己会慢慢变形。几千个粒子顺着风走并拖出渐隐的尾巴，`r`n像烟、像洋流、像丝绸里的纹路。同一股气流里的粒子颜色接近。"

    Init = {
        param($ctx)
        if (-not ('FlowField' -as [type])) {
            Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $FlowCSharp
        }
        # 粒子数跟着分辨率走，保证每帧成本大体不变
        $n = [int]([Math]::Min(9000, [Math]::Max(2500, $ctx.W * $ctx.H / 600)))
        $o = New-Object FlowField -ArgumentList $ctx.W, $ctx.H, $n, $ctx.Rnd.Next()
        @{
            o  = $o
            bg = [System.Drawing.Color]::FromArgb(8, 9, 15)
            fg = [System.Drawing.Color]::FromArgb(150, 200, 230)
        }
    }

    Update = { param($ctx, $st) $st.o.Step() }
    Draw   = { param($ctx, $st, $g) $st.o.Draw($g) }
    Theme  = { param($ctx, $st) @{ Bg = $st.bg; Fg = $st.fg } }
}
