# ============================================================
#  皮肤：小恐龙（Chrome 离线小恐龙，自动驾驶版）
#  被主程序「点源」加载：这里定义的函数会进主程序的作用域，所以名字都带 Dino 前缀。
#  状态一律放在 Init 返回的哈希表里，别往 $script: 里塞。
# ============================================================

function New-DinoFill([int]$y1, [int]$y2, [int]$x1, [int]$x2) {
    $o = @()
    for ($y = $y1; $y -le $y2; $y++) { $o += ,@($y, $x1, $x2) }
    ,$o
}
function New-DinoGrid([int]$Width, [int]$Height, [object[]]$Segs) {
    $grid = @()
    for ($y = 0; $y -lt $Height; $y++) {
        $row = New-Object 'char[]' $Width
        for ($x = 0; $x -lt $Width; $x++) { $row[$x] = ' ' }
        $grid += ,$row
    }
    foreach ($s in $Segs) {
        $y = [int]$s[0]; $x1 = [int]$s[1]; $x2 = [int]$s[2]
        if ($y -lt 0 -or $y -ge $Height) { continue }
        for ($x = $x1; $x -le $x2; $x++) { if ($x -ge 0 -and $x -lt $Width) { $grid[$y][$x] = '#' } }
    }
    $rows = @()
    foreach ($r in $grid) { $rows += (-join $r) }
    ,$rows
}
function New-DinoSprite([string[]]$Rows, [int]$Scale, [System.Drawing.Color]$Color) {
    $w = [int](($Rows | Measure-Object -Property Length -Maximum).Maximum)
    $h = [int]$Rows.Count
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList ($w * $Scale), ($h * $Scale)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $br  = New-Object System.Drawing.SolidBrush $Color
    for ($y = 0; $y -lt $h; $y++) {
        $row = $Rows[$y]
        for ($x = 0; $x -lt $row.Length; $x++) {
            if ($row[$x] -ne ' ') { $g.FillRectangle($br, $x * $Scale, $y * $Scale, $Scale, $Scale) }
        }
    }
    $br.Dispose(); $g.Dispose()
    $bmp
}

function Add-DinoObstacle($st) {
    $rnd = $st.rnd
    $u   = $st.u
    $r = $rnd.Next(0, 100)
    if ($r -lt 30) {
        $n = $rnd.Next(1, 4)
        [void]$st.obstacles.Add([pscustomobject]@{
            Kind='cactus'; Key='cactusS'; X=[double]$st.W; W=([int](11*$u)) * $n; HH=([int](18*$u)); N=$n })
    } elseif ($r -lt 60) {
        $n = $rnd.Next(1, 3)
        [void]$st.obstacles.Add([pscustomobject]@{
            Kind='cactus'; Key='cactusL'; X=[double]$st.W; W=([int](14*$u)) * $n; HH=([int](26*$u)); N=$n })
    } elseif ($r -lt 78) {
        [void]$st.obstacles.Add([pscustomobject]@{
            Kind='cactus'; Key='cactusS'; X=[double]$st.W; W=([int](11*$u)); HH=([int](18*$u)); N=1 })
    } else {
        [void]$st.obstacles.Add([pscustomobject]@{
            Kind='bird'; Key='bird'; X=[double]$st.W; W=([int](20*$u)); HH=([int](16*$u)); N=1 })
    }
    $st.nextSpawn = $rnd.Next(22, 58)
}

@{
    Id    = 'dino'
    Title = '小恐龙'
    Desc  = "Chrome 离线小恐龙。它自己跑、自己跳仙人掌、自己趴下躲翼龙；`r`n每 700 分昼夜切一次，最高分存在 hiscore.txt。"

    Init = {
        param($ctx)
        $scale = $ctx.Scale; $W = $ctx.W; $H = $ctx.H; $rnd = $ctx.Rnd

        $COL_DAY_BG   = [System.Drawing.Color]::FromArgb(247,247,247)
        $COL_DAY_FG   = [System.Drawing.Color]::FromArgb(83,83,83)
        $COL_NIGHT_BG = [System.Drawing.Color]::FromArgb(28,28,30)
        $COL_NIGHT_FG = [System.Drawing.Color]::FromArgb(238,238,238)

        # ---- 恐龙（宽 24 高 22 个像素单位）----
        $DinoBody = @(
            @(0,16,22), @(1,15,23),
            @(2,15,17), @(2,19,23),          # 18 号格留空 = 眼睛
            @(3,15,23), @(4,15,23), @(5,15,23), @(6,15,21),
            @(6,13,21), @(7,12,19), @(8,11,19),
            @(9,6,19), @(10,3,19), @(11,0,19), @(12,0,18), @(13,1,17), @(14,3,16), @(15,5,15),
            @(13,17,19), @(14,17,19)
        )
        $LegsA = @(@(16,6,8),@(17,6,8),@(18,6,8),@(19,6,8),@(20,6,8),@(21,6,10), @(16,12,14),@(17,12,14),@(18,13,14))
        $LegsB = @(@(16,6,8),@(17,6,8),@(18,7,8), @(16,12,14),@(17,12,14),@(18,12,14),@(19,12,14),@(20,12,14),@(21,12,16))
        $LegsJ = @(@(16,6,8),@(17,6,8),@(18,6,8),@(19,6,8),@(20,6,8),@(21,6,10), @(16,12,14),@(17,12,14),@(18,12,14),@(19,12,14),@(20,12,14),@(21,12,16))

        # ---- 趴下躲鸟（宽 26 高 12）----
        $DuckBody = @(
            @(0,15,24), @(1,14,19), @(1,21,25), @(2,13,25), @(3,10,25),
            @(4,0,24), @(5,0,23), @(6,2,21), @(7,4,18)
        )
        $DuckA = @(@(8,5,7),@(9,5,7),@(10,5,7),@(11,5,8), @(8,12,14),@(9,12,14))
        $DuckB = @(@(8,5,7),@(9,5,7), @(8,12,14),@(9,12,14),@(10,12,14),@(11,12,15))

        # ---- 仙人掌 ----
        $CactusS = (New-DinoFill 0 17 4 6) + (New-DinoFill 5 11 1 2) + (New-DinoFill 10 11 2 4) + (New-DinoFill 7 13 8 9) + (New-DinoFill 12 13 6 8)
        $CactusL = (New-DinoFill 0 25 5 8) + (New-DinoFill 7 17 1 3) + (New-DinoFill 15 17 3 5) + (New-DinoFill 10 20 10 12) + (New-DinoFill 18 20 8 10)

        # ---- 翼龙（宽 20 高 16，身体恒在第 8~10 行，换翅膀不跳位）----
        $BirdBody = @(@(8,8,15), @(9,7,16), @(10,9,14), @(9,0,7), @(10,3,6), @(7,10,13))
        $WingUp   = @(@(0,11,13), @(1,11,14), @(2,10,14), @(3,10,15), @(4,9,15), @(5,9,16), @(6,9,16), @(7,14,16))
        $WingDown = @(@(11,9,16), @(12,9,15), @(13,10,15), @(14,10,14), @(15,11,14))

        # ---- 云 ----
        $CloudSeg = @(@(0,7,12), @(1,4,15), @(2,2,17), @(3,0,19), @(4,0,19), @(5,2,17), @(6,5,14))

        $SpriteDefs = @{
            dinoA   = @{ W=24; H=22; S=($DinoBody + $LegsA) }
            dinoB   = @{ W=24; H=22; S=($DinoBody + $LegsB) }
            dinoJ   = @{ W=24; H=22; S=($DinoBody + $LegsJ) }
            duckA   = @{ W=26; H=12; S=($DuckBody + $DuckA) }
            duckB   = @{ W=26; H=12; S=($DuckBody + $DuckB) }
            cactusS = @{ W=11; H=18; S=$CactusS }
            cactusL = @{ W=14; H=26; S=$CactusL }
            birdA   = @{ W=20; H=16; S=($BirdBody + $WingUp) }
            birdB   = @{ W=20; H=16; S=($BirdBody + $WingDown) }
            cloud   = @{ W=20; H=7;  S=$CloudSeg }
        }

        $SP = @{}
        foreach ($k in $SpriteDefs.Keys) {
            $d    = $SpriteDefs[$k]
            $rows = New-DinoGrid -Width $d.W -Height $d.H -Segs $d.S
            $SP["day.$k"]   = New-DinoSprite $rows $scale $COL_DAY_FG
            $SP["night.$k"] = New-DinoSprite $rows $scale $COL_NIGHT_FG
        }

        $groundY = [int]($H * 0.66)
        $dotH    = [Math]::Max(2, [int]($scale / 2))    # 地面碎石 / 地平线的粗细
        $skyTop  = [int]($H * 0.10)
        $skyBot  = [int]($groundY * 0.55)
        $groundSpan = $W * 2

        $AIR_FRAMES = 21.0
        $JUMP_H     = [int](36 * $scale)
        $GRAV       = 8.0 * $JUMP_H / ($AIR_FRAMES * $AIR_FRAMES)

        $hiFile = Join-Path $ctx.Dir 'hiscore.txt'
        $hi = 0
        if (Test-Path $hiFile) { try { $hi = [int]((Get-Content $hiFile -Raw).Trim()) } catch { $hi = 0 } }

        $pebbles = @()
        for ($i = 0; $i -lt 120; $i++) {
            $px = [int]$rnd.Next(0, $groundSpan)
            $py = [int]($rnd.Next(2, 9) * $dotH)
            $pl = [int]($rnd.Next(1, 4) * $scale)
            $pebbles += ,@($px, $py, $pl)
        }
        $stars = @()
        for ($i = 0; $i -lt 45; $i++) {
            $sx = [int]$rnd.Next(0, $W)
            $sy = [int]$rnd.Next(0, $skyBot)
            $ss = [int]($rnd.Next(1, 3) * $dotH)
            $stars += ,@($sx, $sy, $ss)
        }
        $clouds = @()
        for ($i = 0; $i -lt 4; $i++) {
            $cx = [double]$rnd.Next(0, $W)
            $cy = [double]$rnd.Next($skyTop, $skyBot)
            $clouds += ,@($cx, $cy)
        }

        @{
            W = $W; H = $H; u = $scale; rnd = $rnd
            SP = $SP
            dayBg = $COL_DAY_BG; dayFg = $COL_DAY_FG; nightBg = $COL_NIGHT_BG; nightFg = $COL_NIGHT_FG
            groundY = $groundY; dotH = $dotH; skyTop = $skyTop; skyBot = $skyBot; groundSpan = $groundSpan
            dinoX = [int]($W * 0.13); dinoW = [int](24 * $scale); dinoH = [int](22 * $scale); duckH = [int](12 * $scale)
            GRAV = $GRAV; VJUMP = ($GRAV * $AIR_FRAMES / 2.0)
            hiFile = $hiFile; hi = $hi
            frame = 0; score = 0; speed = (6.5 * $scale)
            yoff = 0.0; vy = 0.0; jumping = $false; ducking = $false; night = $false
            obstacles = (New-Object System.Collections.ArrayList); nextSpawn = 40; groundX = 0.0
            pebbles = $pebbles; stars = $stars; clouds = $clouds
        }
    }

    Update = {
        param($ctx, $st)
        $rnd = $st.rnd
        $st.frame++
        if ($st.frame % 3 -eq 0) {
            $st.score++
            if ($st.score -gt $st.hi) { $st.hi = $st.score }
        }
        $st.speed = [Math]::Min(11.5 * $st.u, 6.5 * $st.u * (1.0 + $st.score / 1500.0))
        # 注意：[int] 是四舍五入，这里必须用 Floor，否则半程就入夜
        $st.night = (((([int][Math]::Floor($st.score / 700.0))) % 2) -eq 1)

        # 地面与云
        $st.groundX = ($st.groundX + $st.speed) % $st.groundSpan
        for ($i = 0; $i -lt $st.clouds.Count; $i++) {
            $c = $st.clouds[$i]
            $c[0] = $c[0] - $st.speed * 0.18
            if ($c[0] -lt -([int](20 * $st.u))) {
                $c[0] = $st.W + $rnd.Next(0, [int]($st.W * 0.4))
                $c[1] = $rnd.Next($st.skyTop, $st.skyBot)
            }
        }

        # 障碍
        $st.nextSpawn--
        if ($st.nextSpawn -le 0) { Add-DinoObstacle $st }
        $dead = @()
        foreach ($o in $st.obstacles) {
            $sp = if ($o.Kind -eq 'bird') { $st.speed * 1.12 } else { $st.speed }
            $o.X = $o.X - $sp
            if (($o.X + $o.W) -lt -10) { $dead += $o }
        }
        foreach ($d in $dead) { $st.obstacles.Remove($d) }

        # 自动驾驶：算最近障碍
        $nearJump = $null; $nearBird = $null
        foreach ($o in $st.obstacles) {
            $gap = $o.X - ($st.dinoX + $st.dinoW)
            if ($o.Kind -eq 'bird') {
                if (($o.X + $o.W) -gt $st.dinoX) { if ($null -eq $nearBird -or $o.X -lt $nearBird.X) { $nearBird = $o } }
            } else {
                if ($gap -gt -$st.dinoW) { if ($null -eq $nearJump -or $o.X -lt $nearJump.X) { $nearJump = $o } }
            }
        }
        # 躲鸟
        $st.ducking = $false
        if ($null -ne $nearBird -and -not $st.jumping) {
            $gap = $nearBird.X - ($st.dinoX + $st.dinoW)
            if ($gap -le $st.speed * 6) { $st.ducking = $true }
        }
        # 起跳
        if (-not $st.jumping -and -not $st.ducking -and $null -ne $nearJump) {
            $gap = $nearJump.X - ($st.dinoX + $st.dinoW)
            if ($gap -gt 0 -and $gap -le $st.speed * 8) {
                $st.jumping = $true
                $st.vy = $st.VJUMP
            }
        }
        if ($st.jumping) {
            $st.yoff = $st.yoff + $st.vy
            $st.vy   = $st.vy - $st.GRAV
            if ($st.yoff -le 0) { $st.yoff = 0; $st.vy = 0; $st.jumping = $false }
        }
    }

    Draw = {
        param($ctx, $st, $g)
        $W = $st.W; $H = $st.H; $u = $st.u
        $pal = if ($st.night) { 'night' } else { 'day' }
        $bg  = if ($st.night) { $st.nightBg } else { $st.dayBg }
        $fg  = if ($st.night) { $st.nightFg } else { $st.dayFg }
        $g.Clear($bg)
        $brush = New-Object System.Drawing.SolidBrush $fg

        if ($st.night) {
            foreach ($s in $st.stars) { $g.FillRectangle($brush, ([int]$s[0]), ([int]$s[1]), ([int]$s[2]), ([int]$s[2])) }
            $mr = [int](9 * $u)
            $mx = [int]($W * 0.78); $my = [int]($H * 0.14)
            $g.FillEllipse($brush, $mx, $my, ($mr * 2), ($mr * 2))
            $bgb = New-Object System.Drawing.SolidBrush $bg
            $g.FillEllipse($bgb, ($mx + [int]($mr * 0.55)), ($my - [int]($mr * 0.25)), ($mr * 2), ($mr * 2))
            $bgb.Dispose()
        }

        foreach ($c in $st.clouds) { $g.DrawImageUnscaled($st.SP["$pal.cloud"], ([int]$c[0]), ([int]$c[1])) }

        # 地面
        $g.FillRectangle($brush, 0, $st.groundY, $W, $st.dotH)
        $off = [int]$st.groundX
        foreach ($p in $st.pebbles) {
            $x = [int]$p[0] - $off
            if ($x -lt -50) { $x += $st.groundSpan }
            if ($x -gt $W) { continue }
            $g.FillRectangle($brush, $x, ($st.groundY + [int]$p[1]), ([int]$p[2]), $st.dotH)
        }

        # 障碍
        foreach ($o in $st.obstacles) {
            if ($o.Kind -eq 'bird') {
                $k = if ((($st.frame % 16) -lt 8)) { 'birdA' } else { 'birdB' }
                $g.DrawImageUnscaled($st.SP["$pal.$k"], ([int]$o.X), ($st.groundY - [int](13 * $u) - $o.HH))
            } else {
                $one = $st.SP["$pal.$($o.Key)"]
                for ($i = 0; $i -lt $o.N; $i++) {
                    $g.DrawImageUnscaled($one, [int]($o.X + $i * $one.Width * 0.82), ($st.groundY - $o.HH))
                }
            }
        }

        # 恐龙
        if ($st.ducking) {
            $k = if ((($st.frame % 8) -lt 4)) { 'duckA' } else { 'duckB' }
            $g.DrawImageUnscaled($st.SP["$pal.$k"], $st.dinoX, ($st.groundY - $st.duckH))
        } elseif ($st.jumping) {
            $g.DrawImageUnscaled($st.SP["$pal.dinoJ"], $st.dinoX, ($st.groundY - $st.dinoH - [int]$st.yoff))
        } else {
            $k = if ((($st.frame % 8) -lt 4)) { 'dinoA' } else { 'dinoB' }
            $g.DrawImageUnscaled($st.SP["$pal.$k"], $st.dinoX, ($st.groundY - $st.dinoH))
        }

        # 记分
        $fnt = New-Object System.Drawing.Font('Consolas', [single]($u * 2.2), [System.Drawing.FontStyle]::Bold)
        $txt = ('HI {0:d5}  {1:d5}' -f $st.hi, $st.score)
        $sz  = $g.MeasureString($txt, $fnt)
        $g.DrawString($txt, $fnt, $brush, ($W - $sz.Width - $u * 6), ($u * 6))
        $fnt.Dispose()
        $brush.Dispose()
    }

    Theme = {
        param($ctx, $st)
        if ($st.night) { @{ Bg = $st.nightBg; Fg = $st.nightFg } }
        else           { @{ Bg = $st.dayBg;   Fg = $st.dayFg   } }
    }

    Close = {
        param($ctx, $st)
        try { Set-Content -Path $st.hiFile -Value ([string]$st.hi) -Encoding ASCII } catch { }
    }
}
