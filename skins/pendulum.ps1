# ============================================================
#  皮肤：双摆混沌
#  一根摆挂着另一根摆，是最经典的混沌系统之一：初值差一丁点，
#  走着走着就完全不是一回事了。
#  这里同时跑 140 个双摆，初始角度只差 0.00001 弧度（肉眼绝对分不出），
#  按色相排好队。开头它们像一条缎带一样整齐，然后慢慢劈叉，
#  最后彻底散成一把彩色扇子——散开的过程就是这张皮肤要看的东西。
#  积分用 RK4，能量几分钟下来基本不漂。
# ============================================================

$PendulumCSharp = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class DoublePendulum {
    private int W, H, N;
    private Random rnd;
    private double[] a1, a2, w1, w2;          // 两节角度和角速度
    private const double G = 9.81, M1 = 1.0, M2 = 1.0, L1 = 1.0, L2 = 1.0;
    private const double DT = 0.0025;         // 积分步长（秒）
    private int SUB = 3;                      // 每帧多少子步。实测 SUB=7 时整个「缎带→扇子」9 秒就演完了，
                                              // 太赶；3 差不多是 7 秒开始分岔、19 秒明显散开、24 秒成扇。
    public int Sub { get { return SUB; } set { SUB = value; } }
    public double Spread;                     // 给测试看的：扇子张开到什么程度（相对臂长）
    private byte[] cr, cg, cb;
    private const int TN = 64;                // 摆尖尾巴留多少帧
    private float[] tx, ty;
    private int tw;
    private double pxo, pyo, Lpx, tipR;
    private int frames, phase;
    private double fade, gain = 1;
    public double EDrift;                     // 给测试看的：能量漂移
    private double E0;
    public int Reseeds;
    // 自己的像素缓冲：140 根摆 × (2 根杆 + 64 点尾巴) ≈ 9000 条线，
    // 交给 GDI+ 逐条画要 140ms/帧；自己画再整屏送一次只要十几毫秒。
    private int[] buf, bgRow;
    private GCHandle hbuf;
    private Bitmap frame;
    private const int BG = unchecked((int)0xFF0A0A0E);
    private int[] iw1, iw0, wt;               // 尾巴每一档的环形下标和亮度，跟具体哪根摆无关

    public DoublePendulum(int w, int h, int n, int seed) {
        W = w; H = h; N = n;
        rnd = new Random(seed);
        a1 = new double[N]; a2 = new double[N]; w1 = new double[N]; w2 = new double[N];
        tx = new float[N * TN]; ty = new float[N * TN];
        cr = new byte[N]; cg = new byte[N]; cb = new byte[N];
        iw1 = new int[TN]; iw0 = new int[TN]; wt = new int[TN];
        buf = new int[W * H];
        bgRow = new int[W];
        for (int i = 0; i < W; i++) bgRow[i] = BG;
        hbuf = GCHandle.Alloc(buf, GCHandleType.Pinned);
        frame = new Bitmap(W, H, W * 4, PixelFormat.Format32bppPArgb, hbuf.AddrOfPinnedObject());
        // 两节臂加起来最多能伸到 2*Lpx，摆能翻过轴顶，所以上下都要留得下：
        // 轴放正中间、总伸长取屏高的一半是能占满的极限
        Lpx = Math.Min(W, H) * 0.24;
        pxo = W / 2.0; pyo = H * 0.5;
        tipR = Math.Max(1.6, Math.Min(W, H) / 520.0);
        for (int i = 0; i < N; i++) {
            // 色相排成一条彩虹，但只走 300 度，免得首尾都是红的分不清
            Color c = FromHsv(300.0 * i / N, 0.78, 1.0);
            cr[i] = c.R; cg[i] = c.G; cb[i] = c.B;
        }
        Seed();
        phase = 2; fade = 1;
    }

    // ---------- 自己的画线：带抗锯齿的加色混合 ----------
    private void Plot(int x, int y, int r, int g, int b) {
        if (x < 0 || x >= W || y < 0 || y >= H) return;
        int idx = y * W + x, p = buf[idx];
        int rr = ((p >> 16) & 0xFF) + r; if (rr > 255) rr = 255;
        int gg = ((p >> 8) & 0xFF) + g;  if (gg > 255) gg = 255;
        int bb = (p & 0xFF) + b;         if (bb > 255) bb = 255;
        buf[idx] = unchecked((int)0xFF000000) | (rr << 16) | (gg << 8) | bb;
    }
    // 沿长轴走，短轴上按小数部分分给相邻两个像素——线细又不锯齿
    private void Line(float x0, float y0, float x1, float y1, int r, int g, int b) {
        float dx = x1 - x0, dy = y1 - y0;
        float adx = Math.Abs(dx), ady = Math.Abs(dy);
        int n = (int)Math.Max(adx, ady);
        if (n <= 0) { Plot((int)x0, (int)y0, r, g, b); return; }
        if (n > 4000) return;
        float sx = dx / n, sy = dy / n, x = x0, y = y0;
        if (adx >= ady) {
            for (int i = 0; i <= n; i++) {
                int xi = (int)x, yi = (int)Math.Floor(y);
                float f = y - yi;
                Plot(xi, yi,     (int)(r * (1 - f)), (int)(g * (1 - f)), (int)(b * (1 - f)));
                Plot(xi, yi + 1, (int)(r * f),       (int)(g * f),       (int)(b * f));
                x += sx; y += sy;
            }
        } else {
            for (int i = 0; i <= n; i++) {
                int xi = (int)Math.Floor(x), yi = (int)y;
                float f = x - xi;
                Plot(xi,     yi, (int)(r * (1 - f)), (int)(g * (1 - f)), (int)(b * (1 - f)));
                Plot(xi + 1, yi, (int)(r * f),       (int)(g * f),       (int)(b * f));
                x += sx; y += sy;
            }
        }
    }
    private void Disc(float cx, float cy, double rad, int r, int g, int b) {
        int x0 = (int)(cx - rad), x1 = (int)(cx + rad), y0 = (int)(cy - rad), y1 = (int)(cy + rad);
        double r2 = rad * rad;
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) {
                double d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy);
                if (d2 <= r2) Plot(x, y, r, g, b);
            }
    }

    private static Color FromHsv(double h, double s, double v) {
        double c = v * s, x = c * (1 - Math.Abs((h / 60.0) % 2 - 1)), m = v - c;
        double r = 0, g = 0, b = 0;
        int k = (int)(h / 60) % 6;
        if (k == 0) { r = c; g = x; } else if (k == 1) { r = x; g = c; }
        else if (k == 2) { g = c; b = x; } else if (k == 3) { g = x; b = c; }
        else if (k == 4) { r = x; b = c; } else { r = c; b = x; }
        return Color.FromArgb((int)((r + m) * 255), (int)((g + m) * 255), (int)((b + m) * 255));
    }

    private void Seed() {
        tw = 0; frames = 0;
        // 起始角度要在「翻得过去」的能量上，不然只是来回荡，根本乱不起来
        double b1 = 1.6 + rnd.NextDouble() * 1.3;
        double b2 = 1.4 + rnd.NextDouble() * 1.6;
        for (int i = 0; i < N; i++) {
            a1[i] = b1 + i * 1e-5;            // 差 0.00001 弧度，肉眼绝对看不出来
            a2[i] = b2;
            w1[i] = 0; w2[i] = 0;
        }
        E0 = Energy(0);
    }

    private double Energy(int i) {
        double t1 = a1[i], t2 = a2[i], u1 = w1[i], u2 = w2[i];
        double ke = 0.5 * M1 * L1 * L1 * u1 * u1
                  + 0.5 * M2 * (L1 * L1 * u1 * u1 + L2 * L2 * u2 * u2
                                + 2 * L1 * L2 * u1 * u2 * Math.Cos(t1 - t2));
        double pe = -(M1 + M2) * G * L1 * Math.Cos(t1) - M2 * G * L2 * Math.Cos(t2);
        return ke + pe;
    }

    // 双摆标准运动方程
    private void Deriv(double t1, double t2, double u1, double u2,
                       out double d1, out double d2) {
        double d = t1 - t2;
        double den = 2 * M1 + M2 - M2 * Math.Cos(2 * d);
        d1 = (-G * (2 * M1 + M2) * Math.Sin(t1)
              - M2 * G * Math.Sin(t1 - 2 * t2)
              - 2 * Math.Sin(d) * M2 * (u2 * u2 * L2 + u1 * u1 * L1 * Math.Cos(d)))
             / (L1 * den);
        d2 = (2 * Math.Sin(d) * (u1 * u1 * L1 * (M1 + M2)
              + G * (M1 + M2) * Math.Cos(t1)
              + u2 * u2 * L2 * M2 * Math.Cos(d)))
             / (L2 * den);
    }

    private void Rk4(int i, double h) {
        double t1 = a1[i], t2 = a2[i], u1 = w1[i], u2 = w2[i];
        double k1a, k1b; Deriv(t1, t2, u1, u2, out k1a, out k1b);
        double k2a, k2b; Deriv(t1 + h / 2 * u1, t2 + h / 2 * u2, u1 + h / 2 * k1a, u2 + h / 2 * k1b, out k2a, out k2b);
        double k3a, k3b; Deriv(t1 + h / 2 * (u1 + h / 2 * k1a), t2 + h / 2 * (u2 + h / 2 * k1b),
                               u1 + h / 2 * k2a, u2 + h / 2 * k2b, out k3a, out k3b);
        double k4a, k4b; Deriv(t1 + h * (u1 + h / 2 * k2a), t2 + h * (u2 + h / 2 * k2b),
                               u1 + h * k3a, u2 + h * k3b, out k4a, out k4b);
        double nu1 = u1 + h / 6 * (k1a + 2 * k2a + 2 * k3a + k4a);
        double nu2 = u2 + h / 6 * (k1b + 2 * k2b + 2 * k3b + k4b);
        a1[i] = t1 + h / 2 * (u1 + nu1);
        a2[i] = t2 + h / 2 * (u2 + nu2);
        w1[i] = nu1; w2[i] = nu2;
    }

    public void Step() {
        if (phase == 1) { fade += 0.05; gain = 1 - fade; if (fade >= 1) { fade = 1; gain = 0; Seed(); Reseeds++; phase = 2; } return; }
        if (phase == 2) { fade -= 0.04; gain = 1 - fade; if (fade <= 0) { fade = 0; gain = 1; phase = 0; } }

        for (int s = 0; s < SUB; s++)
            for (int i = 0; i < N; i++) Rk4(i, DT);
        frames++;

        int slot = tw % TN;
        for (int i = 0; i < N; i++) {
            double jx = pxo + Lpx * Math.Sin(a1[i]), jy = pyo + Lpx * Math.Cos(a1[i]);
            tx[i * TN + slot] = (float)(jx + Lpx * Math.Sin(a2[i]));
            ty[i * TN + slot] = (float)(jy + Lpx * Math.Cos(a2[i]));
        }
        tw++;

        // 张开度：所有摆尖离第一根摆尖的最远距离，除以臂长
        int last = (tw - 1 + TN) % TN;
        double sp = 0, bx = tx[last], by = ty[last];
        for (int i = 1; i < N; i++) {
            double dx = tx[i * TN + last] - bx, dy = ty[i * TN + last] - by;
            double d = Math.Sqrt(dx * dx + dy * dy);
            if (d > sp) sp = d;
        }
        Spread = sp / Lpx;

        EDrift = Math.Abs((Energy(0) - E0) / E0);
        // 散透了就重开：这时候满屏均匀彩色糊，已经没有「一起走再劈叉」可看了
        if (frames > 1600 || EDrift > 0.05) phase = 1;   // 约 50 秒一轮：演完还留 20 秒看满屏的扇子
    }

    public void Draw(Graphics g) {
        for (int y = 0; y < H; y++) Array.Copy(bgRow, 0, buf, y * W, W);
        // 淡入淡出直接乘在亮度上，省掉一次整屏叠加
        double gn = gain;

        // 杆子：画得很淡，一百多根叠在一起才有「一把扇子」的质感
        int rodI = (int)(26 * gn);
        if (rodI > 0) {
            for (int i = 0; i < N; i++) {
                float jx = (float)(pxo + Lpx * Math.Sin(a1[i])), jy = (float)(pyo + Lpx * Math.Cos(a1[i]));
                float ex = (float)(jx + Lpx * Math.Sin(a2[i])), ey = (float)(jy + Lpx * Math.Cos(a2[i]));
                int r = cr[i] * rodI / 255, gg = cg[i] * rodI / 255, b = cb[i] * rodI / 255;
                Line((float)pxo, (float)pyo, jx, jy, r, gg, b);
                Line(jx, jy, ex, ey, r, gg, b);
            }
        }

        // 摆尖的尾巴。每一档的环形下标和亮度跟「哪根摆」无关，先算好，
        // 免得在 140×64 的内层循环里反复做取模和除法。
        int have = Math.Min(tw, TN);
        for (int k = 1; k < have; k++) {
            iw1[k] = (tw - k + TN * 2) % TN;
            iw0[k] = (tw - k - 1 + TN * 2) % TN;
            double f = 1.0 - (double)k / have;
            wt[k] = (int)(f * f * 210 * gn);
        }
        for (int i = 0; i < N; i++) {
            int bi = i * TN;
            for (int k = 1; k < have; k++) {
                int w = wt[k];
                if (w <= 2) continue;
                Line(tx[bi + iw0[k]], ty[bi + iw0[k]], tx[bi + iw1[k]], ty[bi + iw1[k]],
                     cr[i] * w / 255, cg[i] * w / 255, cb[i] * w / 255);
            }
        }

        // 摆尖
        int tipI = (int)(255 * gn);
        if (tipI > 0) {
            int idx = (tw - 1 + TN) % TN;
            for (int i = 0; i < N; i++)
                Disc(tx[i * TN + idx], ty[i * TN + idx], tipR,
                     cr[i] * tipI / 255, cg[i] * tipI / 255, cb[i] * tipI / 255);
            // 轴
            Disc((float)pxo, (float)pyo, tipR * 1.2, (int)(150 * gn), (int)(155 * gn), (int)(170 * gn));
        }

        CompositingMode old = g.CompositingMode;
        g.CompositingMode = CompositingMode.SourceCopy;
        g.DrawImageUnscaled(frame, 0, 0);
        g.CompositingMode = old;
    }
}
'@

@{
    Id    = 'pendulum'
    Title = '双摆混沌'
    Desc  = "140 个双摆，初始角度只差 0.00005 弧度，按色相排队。`r`n开头它们像一条缎带一样整齐，然后慢慢劈叉，最后散成一把彩色扇子——`r`n散开的过程就是混沌本身。散透了自动重开。"

    Init = {
        param($ctx)
        if (-not ('DoublePendulum' -as [type])) {
            Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $PendulumCSharp
        }
        $o = New-Object DoublePendulum -ArgumentList $ctx.W, $ctx.H, 140, $ctx.Rnd.Next()
        @{
            o  = $o
            bg = [System.Drawing.Color]::FromArgb(10, 10, 14)
            fg = [System.Drawing.Color]::FromArgb(180, 185, 200)
        }
    }

    Update = { param($ctx, $st) $st.o.Step() }
    Draw   = { param($ctx, $st, $g) $st.o.Draw($g) }
    Theme  = { param($ctx, $st) @{ Bg = $st.bg; Fg = $st.fg } }
}
