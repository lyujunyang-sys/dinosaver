# ============================================================
#  皮肤：三星系统
#  每次都是现摇的随机三体：随机质量、随机位置、随机速度，之后就只有万有引力说了算。
#  没有预设轨道、没有循环动画——同一颗种子跑两次才会一样。
#
#  随机三体真正难的不是渲染，是这两件事：
#    ① 近距离掠过时加速度爆表，固定步长的积分器会把能量算飞 → 自适应步长（+ 一点软化）
#    ② 随机三体迟早会甩出去一颗、剩两颗结成双星，这是真实结局不是 bug
#       → 认出被甩出去的那颗，镜头跟住留下的双星，让它自己飞出画面，然后淡出重摇
#  物理和渲染都在 C# 里，PS 这边一帧只调两次方法。
# ============================================================

$OrbitCSharp = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

public class Orbit3 {
    private int W, H;
    private Random rnd;
    private double[] px = new double[3], py = new double[3];
    private double[] vx = new double[3], vy = new double[3];
    private double[] ax = new double[3], ay = new double[3];
    private double[] m  = new double[3];
    private Color[] bcol = new Color[3];
    private static readonly Color[] PALETTE = new Color[] {
        Color.FromArgb(255, 186,  92),   // 金橙
        Color.FromArgb(105, 200, 255),   // 冰蓝
        Color.FromArgb(240, 120, 210)    // 品红
    };
    private Bitmap[] glow = new Bitmap[3];
    // 背景星空：别烤成整屏位图。整屏 1920×1080 的 DrawImage 要 20ms，
    // 而 g.Clear + 150 个小方块只要 5ms 多——这张图本来就只有 150 颗星。
    private int[] stx, sty, sts, stb;
    private Brush[] stbr;
    private Color bgc = Color.FromArgb(6, 7, 12);
    private Pen[][] tpen;
    private const int PL = 16;          // 尾巴透明度档数
    private const int TN = 420;         // 尾巴留多少帧（32fps ≈ 13 秒）
    private double[,] tx = new double[3, TN], ty = new double[3, TN];
    private int tw;
    private PointF[] ptbuf = new PointF[TN + 2];   // 投影后的尾巴点，复用不重新分配

    // 视角：世界坐标的中心和缩放，都是平滑跟随的
    private double vcx, vcy, vscale;
    private double rot, rotSpd;

    // 积分
    private const double FRAME_T = 0.011;   // 每帧推进多少个时间单位（慢一点，缠斗看得清）
    private const double ETA     = 0.03;    // 自适应步长的胆子，越小越准越慢
    private const double EPS     = 0.03;    // 软化长度：近距离时不让加速度冲到无穷
    private double eps2 = EPS * EPS;
    private double E0;

    // 生死状态
    private int phase;           // 0=正常跑 1=淡出 2=淡入
    private double fade;
    private int frames, escIdx = -1, escGone;
    private int quiet;           // 已经「一对在转、一个在看戏」连续多少帧

    // 给测试看的
    public int Reseeds;
    public double EDrift, SimTime;
    public float[] LastScreen = new float[6];

    public Orbit3(int w, int h, int seed) {
        W = w; H = h;
        rnd = new Random(seed);
        BuildStars();
        tpen = new Pen[3][];
        Seed();
        phase = 2; fade = 1;
    }

    // ---------- 初始条件 ----------
    private void Seed() {
        tw = 0; frames = 0; escIdx = -1; escGone = 0; quiet = 0;
        rotSpd = (rnd.Next(2) == 0 ? 1 : -1) * (0.0002 + rnd.NextDouble() * 0.0006);

        // 质量 0.6~2.0，归一到总和 3：有轻有重，重的拖着轻的跑才好看
        double ms = 0;
        for (int i = 0; i < 3; i++) { m[i] = 0.6 + rnd.NextDouble() * 1.4; ms += m[i]; }
        for (int i = 0; i < 3; i++) m[i] *= 3.0 / ms;

        // 位置：盘里随机撒，彼此至少隔开一点，别一上来就贴脸
        for (int i = 0; i < 3; i++) {
            for (int t = 0; t < 300; t++) {
                double a = rnd.NextDouble() * Math.PI * 2, r = 0.35 + rnd.NextDouble() * 0.85;
                px[i] = r * Math.Cos(a); py[i] = r * Math.Sin(a);
                bool ok = true;
                for (int j = 0; j < i; j++) if (Dist(i, j) < 0.45) ok = false;
                if (ok) break;
            }
        }
        // 速度先随便给个方向和量级
        for (int i = 0; i < 3; i++) {
            double a = rnd.NextDouble() * Math.PI * 2, s = 0.5 + rnd.NextDouble();
            vx[i] = s * Math.Cos(a); vy[i] = s * Math.Sin(a);
        }
        // 质心挪到原点、总动量清零：这样质心永远不动，尾巴可以直接存世界坐标
        double mt = m[0] + m[1] + m[2];
        double cx = 0, cy = 0, qx = 0, qy = 0;
        for (int i = 0; i < 3; i++) { cx += m[i] * px[i]; cy += m[i] * py[i]; qx += m[i] * vx[i]; qy += m[i] * vy[i]; }
        cx /= mt; cy /= mt; qx /= mt; qy /= mt;
        for (int i = 0; i < 3; i++) { px[i] -= cx; py[i] -= cy; vx[i] -= qx; vy[i] -= qy; }

        // 按位力比定总动能：Q = KE/|PE|。Q<1 才是束缚系统；
        // 0.3~0.6 这段最耐看——既乱得起来，又不会三秒就散伙。
        double pe = PE(), ke = KE();
        double Q = 0.30 + rnd.NextDouble() * 0.30;
        double f = Math.Sqrt(Q * Math.Abs(pe) / ke);
        for (int i = 0; i < 3; i++) { vx[i] *= f; vy[i] *= f; }

        Accel();
        E0 = KE() + PE();
        SimTime = 0;

        // 三颗星三个固定颜色，一眼能分清谁是谁（之前按质量调色，
        // 结果随机出来的三个质量往往差不多，看着就是三颗一样的星）。
        // 质量改成只管大小：重的那颗明显更大一圈。
        for (int i = 0; i < 3; i++) {
            double t = (m[i] - 0.6) / 1.4; if (t < 0) t = 0; if (t > 1) t = 1;
            bcol[i] = PALETTE[i];
            if (glow[i] != null) glow[i].Dispose();
            int gs = (int)(Math.Min(W, H) * (0.055 + 0.030 * Math.Pow(m[i] / 1.0, 1.0 / 3.0)));
            if (gs < 24) gs = 24;
            glow[i] = MakeGlow(bcol[i], gs);

            float pw = (float)Math.Max(1.3, Math.Min(W, H) / 700.0 * (0.75 + 0.5 * t));
            tpen[i] = new Pen[PL];
            for (int l = 0; l < PL; l++) {
                int a = (int)(225.0 * Math.Pow((l + 1) / (double)PL, 2.2));
                tpen[i][l] = new Pen(Color.FromArgb(a, bcol[i]), pw);
                tpen[i][l].StartCap = LineCap.Round;
                tpen[i][l].EndCap = LineCap.Round;
            }
        }

        // 镜头一步到位，别从上一局的构图慢慢挪过来
        double r0 = FocusRadius();
        vcx = 0; vcy = 0;
        vscale = Math.Min(W, H) * 0.40 / r0;
    }

    private double Dist(int i, int j) {
        double dx = px[i] - px[j], dy = py[i] - py[j];
        return Math.Sqrt(dx * dx + dy * dy);
    }
    private double KE() {
        double k = 0;
        for (int i = 0; i < 3; i++) k += 0.5 * m[i] * (vx[i] * vx[i] + vy[i] * vy[i]);
        return k;
    }
    private double PE() {
        double p = 0;
        for (int i = 0; i < 3; i++)
            for (int j = i + 1; j < 3; j++)
                p -= m[i] * m[j] / Math.Sqrt(Dist(i, j) * Dist(i, j) + eps2);
        return p;
    }
    private void Accel() {
        for (int i = 0; i < 3; i++) { ax[i] = 0; ay[i] = 0; }
        for (int i = 0; i < 3; i++)
            for (int j = i + 1; j < 3; j++) {
                double dx = px[j] - px[i], dy = py[j] - py[i];
                double r2 = dx * dx + dy * dy + eps2;
                double inv = 1.0 / (r2 * Math.Sqrt(r2));
                ax[i] += m[j] * dx * inv; ay[i] += m[j] * dy * inv;
                ax[j] -= m[i] * dx * inv; ay[j] -= m[i] * dy * inv;
            }
    }

    // 步长跟着最近的那一对走：自由落体时标和相对速度穿越时标取小的
    private double AdaptiveDt() {
        double best = 1e9;
        for (int i = 0; i < 3; i++)
            for (int j = i + 1; j < 3; j++) {
                double dx = px[j] - px[i], dy = py[j] - py[i];
                double r = Math.Sqrt(dx * dx + dy * dy + eps2);
                double tff = Math.Sqrt(r * r * r / (m[i] + m[j]));
                double dvx = vx[j] - vx[i], dvy = vy[j] - vy[i];
                double v = Math.Sqrt(dvx * dvx + dvy * dvy) + 1e-12;
                double tcr = r / v;
                double t = Math.Min(tff, tcr);
                if (t < best) best = t;
            }
        double dt = ETA * best;
        if (dt > 0.004) dt = 0.004;
        if (dt < 2e-7) dt = 2e-7;
        return dt;
    }

    // 蛙跳（踢-漂-踢）：变步长下也守得住，近距离掠过不会把能量算飞
    private void Advance(double dt) {
        for (int i = 0; i < 3; i++) { vx[i] += 0.5 * ax[i] * dt; vy[i] += 0.5 * ay[i] * dt; }
        for (int i = 0; i < 3; i++) { px[i] += vx[i] * dt; py[i] += vy[i] * dt; }
        Accel();
        for (int i = 0; i < 3; i++) { vx[i] += 0.5 * ax[i] * dt; vy[i] += 0.5 * ay[i] * dt; }
    }

    // 谁被甩出去了：离另外两颗的质心远到一定程度、相对那两颗的能量为正、而且还在往外跑
    private void CheckEscape() {
        if (escIdx >= 0) return;
        for (int i = 0; i < 3; i++) {
            int j = (i + 1) % 3, k = (i + 2) % 3;
            double mb = m[j] + m[k];
            double bx = (m[j] * px[j] + m[k] * px[k]) / mb, by = (m[j] * py[j] + m[k] * py[k]) / mb;
            double bvx = (m[j] * vx[j] + m[k] * vx[k]) / mb, bvy = (m[j] * vy[j] + m[k] * vy[k]) / mb;
            double dx = px[i] - bx, dy = py[i] - by;
            double r = Math.Sqrt(dx * dx + dy * dy);
            double rjk = Dist(j, k);
            if (r < 4.5 * rjk || r < 2.5) continue;
            double dvx = vx[i] - bvx, dvy = vy[i] - bvy;
            if (dx * dvx + dy * dvy <= 0) continue;                 // 还在往回走，不算跑掉
            double e = 0.5 * (dvx * dvx + dvy * dvy) - (mb + m[i]) / r;
            if (e > 0) { escIdx = i; return; }
        }
    }

    // 镜头只跟「还绑在一起」的那些星
    private double FocusRadius() {
        double cx, cy; FocusCenter(out cx, out cy);
        double mx = 0;
        for (int i = 0; i < 3; i++) {
            if (i == escIdx) continue;
            double dx = px[i] - cx, dy = py[i] - cy;
            double r = Math.Sqrt(dx * dx + dy * dy);
            if (r > mx) mx = r;
        }
        return Math.Max(mx * 1.35, 0.30);   // 下限：双星缠成一团时别把镜头怼上去
    }
    private void FocusCenter(out double cx, out double cy) {
        double mt = 0; cx = 0; cy = 0;
        for (int i = 0; i < 3; i++) {
            if (i == escIdx) continue;
            cx += m[i] * px[i]; cy += m[i] * py[i]; mt += m[i];
        }
        cx /= mt; cy /= mt;
    }

    public void Step() {
        if (phase == 1) {                      // 淡出
            fade += 0.05;
            if (fade >= 1) { fade = 1; Seed(); Reseeds++; phase = 2; }
            return;
        }
        if (phase == 2) { fade -= 0.04; if (fade <= 0) { fade = 0; phase = 0; } }

        double t = 0; int guard = 0;
        while (t < FRAME_T && guard < 40000) {
            double dt = AdaptiveDt();
            if (dt > FRAME_T - t) dt = FRAME_T - t;
            Advance(dt);
            t += dt; guard++;
        }
        SimTime += t;
        frames++;

        double e = KE() + PE();
        EDrift = Math.Abs((e - E0) / E0);

        int slot = tw % TN;
        for (int i = 0; i < 3; i++) { tx[i, slot] = px[i]; ty[i, slot] = py[i]; }
        tw++;

        if ((frames % 8) == 0) CheckEscape();

        // 好看的是三颗互相缠斗那一段。塌成「两颗抱团转、第三颗在远处看戏」就没得看了。
        // 门槛是量出来的：最远/最近间距之比，中位数 2.6、p75 3.9、p90 6.7——
        // 也就是说 3 倍左右完全是正常缠斗（第三颗荡出去还会荡回来），
        // 真正的「看戏」是 8 倍以上（只占 8% 的帧）。所以门槛取 6，
        // 攒够 200 帧（约 6 秒）都这么散就收摊重摇。
        // 漏桶而不是一不满足就清零：第三颗在门槛附近蹭来蹭去时，
        // 清零会让计数永远攒不满，于是又能赖着看半分钟戏。
        double dmin = 1e18, dmax = 0;
        for (int i = 0; i < 3; i++)
            for (int j = i + 1; j < 3; j++) {
                double d = Dist(i, j);
                if (d < dmin) dmin = d;
                if (d > dmax) dmax = d;
            }
        if (dmax / Math.Max(dmin, 1e-9) > 6.0) quiet++; else quiet -= 3;
        if (quiet < 0) quiet = 0;

        double fcx, fcy; FocusCenter(out fcx, out fcy);
        double want = Math.Min(W, H) * 0.40 / FocusRadius();
        vcx += (fcx - vcx) * 0.03;
        vcy += (fcy - vcy) * 0.03;
        vscale += (want - vscale) * 0.03;
        rot += rotSpd;

        // 被甩出去那颗飞出画面之后再看几秒双星，然后淡出重摇
        if (escIdx >= 0) {
            float sx, sy; Project(px[escIdx], py[escIdx], out sx, out sy);
            if (sx < -80 || sx > W + 80 || sy < -80 || sy > H + 80) escGone++;
            if (escGone > 90) phase = 1;
        }
        // 塌成层级了 / 数值算飞了 / 这局看够了，都重摇
        bool bad = double.IsNaN(px[0]) || double.IsNaN(py[0]) || EDrift > 0.35;
        if (bad || quiet > 200 || frames > 2400) phase = 1;
    }

    private void Project(double wx, double wy, out float sx, out float sy) {
        double ca = Math.Cos(rot), sa = Math.Sin(rot);
        double rx = wx - vcx, ry = wy - vcy;
        sx = (float)(W / 2.0 + vscale * (ca * rx - sa * ry));
        sy = (float)(H / 2.0 + vscale * (sa * rx + ca * ry));
    }

    public void Draw(Graphics g) {
        g.SmoothingMode = SmoothingMode.None;
        g.Clear(bgc);
        for (int i = 0; i < stx.Length; i++) g.FillRectangle(stbr[stb[i]], stx[i], sty[i], sts[i], sts[i]);
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // 尾巴按透明度分档，一档攒成一条折线用 DrawLines 一次画完。
        // 逐段 DrawLine 是 3×420=1260 次调用，光调用开销就吃掉一帧预算；
        // 分档折线降到 3×16 次，画出来的东西一模一样。
        int have = Math.Min(tw, TN);
        if (have > 1) {
            for (int i = 0; i < 3; i++) {
                for (int k = 0; k < have; k++) {
                    int idx = (tw - have + k) % TN;
                    float sx, sy; Project(tx[i, idx], ty[i, idx], out sx, out sy);
                    ptbuf[k] = new PointF(sx, sy);
                }
                int start = 0;
                for (int lv = 0; lv < PL; lv++) {
                    int end = (int)((double)(lv + 1) / PL * (have - 1));
                    if (end <= start) continue;
                    int n = end - start + 1;
                    PointF[] seg = new PointF[n];
                    Array.Copy(ptbuf, start, seg, 0, n);
                    g.DrawLines(tpen[i][lv], seg);
                    start = end;            // 下一档从这个点接上，档与档之间不留缝
                }
            }
        }

        for (int i = 0; i < 3; i++) {
            float sx, sy; Project(px[i], py[i], out sx, out sy);
            LastScreen[i * 2] = sx; LastScreen[i * 2 + 1] = sy;
            Bitmap b = glow[i];
            g.DrawImageUnscaled(b, (int)(sx - b.Width / 2), (int)(sy - b.Height / 2));
        }

        if (fade > 0) {
            int a = (int)(255 * Math.Min(1, fade));
            using (var br = new SolidBrush(Color.FromArgb(a, 6, 7, 12)))
                g.FillRectangle(br, 0, 0, W, H);
        }
    }

    private Bitmap MakeGlow(Color c, int size) {
        Bitmap b = new Bitmap(size, size);
        using (Graphics g = Graphics.FromImage(b)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using (var path = new GraphicsPath()) {
                path.AddEllipse(0, 0, size, size);
                using (var pg = new PathGradientBrush(path)) {
                    pg.CenterColor = Color.FromArgb(220, c);
                    pg.SurroundColors = new Color[] { Color.FromArgb(0, c) };
                    pg.FocusScales = new PointF(0.04f, 0.04f);
                    g.FillEllipse(pg, 0, 0, size, size);
                }
            }
            Color core = Color.FromArgb(255, Math.Min(255, c.R + 70), Math.Min(255, c.G + 70), Math.Min(255, c.B + 70));
            float cr = size * 0.105f;
            using (var br = new SolidBrush(core)) g.FillEllipse(br, size / 2f - cr, size / 2f - cr, cr * 2, cr * 2);
        }
        return b;
    }

    // 背景星空：位置固定，亮度分 6 档共用画刷，每帧直接画
    private void BuildStars() {
        int n = (W * H) / 14000;
        stx = new int[n]; sty = new int[n]; sts = new int[n]; stb = new int[n];
        stbr = new Brush[6];
        for (int l = 0; l < 6; l++)
            stbr[l] = new SolidBrush(Color.FromArgb(35 + l * 30, 210, 220, 255));
        for (int i = 0; i < n; i++) {
            stx[i] = rnd.Next(W); sty[i] = rnd.Next(H);
            sts[i] = rnd.Next(100) < 12 ? 2 : 1;
            stb[i] = rnd.Next(6);
        }
    }
}
'@

@{
    Id    = 'orbit'
    Title = '三星系统'
    Desc  = "每次现摇的随机三体：随机质量、随机位置、随机速度，之后全听万有引力的。`r`n重的偏蓝白、轻的偏橙红；甩出去一颗剩一对双星是真实结局，镜头跟住双星，`r`n等那颗飞出画面就淡出重摇。"

    Init = {
        param($ctx)
        if (-not ('Orbit3' -as [type])) {
            Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $OrbitCSharp
        }
        $o = New-Object Orbit3 -ArgumentList $ctx.W, $ctx.H, $ctx.Rnd.Next()
        @{
            o  = $o
            bg = [System.Drawing.Color]::FromArgb(6, 7, 12)
            fg = [System.Drawing.Color]::FromArgb(170, 180, 200)
        }
    }

    Update = { param($ctx, $st) $st.o.Step() }
    Draw   = { param($ctx, $st, $g) $st.o.Draw($g) }
    Theme  = { param($ctx, $st) @{ Bg = $st.bg; Fg = $st.fg } }
}
