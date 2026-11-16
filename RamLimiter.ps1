[CmdletBinding()]
param(
    [switch]$Child,
    [switch]$Minimized
)

$ScriptPath = $PSCommandPath
$HostName = [System.IO.Path]::GetFileNameWithoutExtension((Get-Process -Id $PID).Path)
$IsExe = ($HostName -notmatch '^(powershell|pwsh)')

# Relanzar oculto y en modo STA (solo cuando se ejecuta como .ps1)
if (-not $Child -and -not $IsExe) {
    $psExe = (Get-Process -Id $PID).Path
    $argList = '-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Child' -f $ScriptPath
    if ($Minimized) { $argList += ' -Minimized' }
    Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# Instancia unica
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ProcessRamLimiterApp', [ref]$createdNew)
if (-not $createdNew) {
    [void][System.Windows.Forms.MessageBox]::Show('RamLimiter ya esta en ejecucion. Buscalo en la bandeja del sistema (junto al reloj).', 'RamLimiter')
    return
}

# Permisos de administrador (para poder cerrar mas procesos)
$IsAdmin = $false
try {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

# ---------- Controles personalizados (C#) ----------
if (-not ('LcSplash' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class RamApi {
    [DllImport("psapi.dll", SetLastError=true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
    [DllImport("user32.dll", EntryPoint="SendMessage", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMsgStr(IntPtr hWnd, int msg, int wParam, string lParam);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool DestroyIcon(IntPtr h);

    public static bool Trim(int pid) {
        IntPtr h = OpenProcess(0x0100 | 0x0400, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return EmptyWorkingSet(h); }
        finally { CloseHandle(h); }
    }
    public static void Round(IntPtr h) { int v = 2; DwmSetWindowAttribute(h, 33, ref v, 4); }
    public static void Drag(IntPtr h) { ReleaseCapture(); SendMessage(h, 0xA1, 2, 0); }

    // ---- Memoria: ordenes directas a Windows ----
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int infoClass, IntPtr info, int length);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetProcessWorkingSetSizeEx(IntPtr h, UIntPtr min, UIntPtr max, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TokPriv1Luid newState, int len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetProcessInformation(IntPtr h, int cls, ref int info, int size);
    [DllImport("kernel32.dll")]
    public static extern bool GlobalMemoryStatusEx(ref MemStatus s);

    [StructLayout(LayoutKind.Sequential, Pack=1)]
    public struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MemStatus {
        public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual;
        public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
    }

    public static bool Priv(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        try {
            TokPriv1Luid tp = new TokPriv1Luid(); tp.Count = 1; tp.Attr = 2;
            if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
            AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return Marshal.GetLastWin32Error() == 0;
        } finally { CloseHandle(tok); }
    }
    // 2 = vaciar working sets de todo el sistema, 3 = escribir paginas modificadas, 5 = purgar standby de baja prioridad
    public static int MemCmd(int cmd) {
        IntPtr p = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(p, cmd); return NtSetSystemInformation(80, p, 4); }
        finally { Marshal.FreeHGlobal(p); }
    }
    public static void CacheTrim() { SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0); }
    public static ulong AvailMB() {
        MemStatus s = new MemStatus(); s.dwLength = (uint)Marshal.SizeOf(typeof(MemStatus));
        GlobalMemoryStatusEx(ref s); return s.ullAvailPhys / 1048576UL;
    }
    public static uint LoadPct() {
        MemStatus s = new MemStatus(); s.dwLength = (uint)Marshal.SizeOf(typeof(MemStatus));
        GlobalMemoryStatusEx(ref s); return s.dwMemoryLoad;
    }
    // Tope duro de working set (Windows obliga al proceso a no pasar de ese tamano)
    public static bool WsCap(int pid, long maxBytes) {
        IntPtr h = OpenProcess(0x0100 | 0x0400, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return SetProcessWorkingSetSizeEx(h, new UIntPtr(204800UL), new UIntPtr((ulong)maxBytes), 0x2 | 0x4); }
        finally { CloseHandle(h); }
    }
    public static bool WsUncap(int pid) {
        IntPtr h = OpenProcess(0x0100 | 0x0400, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return SetProcessWorkingSetSizeEx(h, new UIntPtr(204800UL), new UIntPtr(2147483647UL), 0x2 | 0x8); }
        finally { CloseHandle(h); }
    }
    // Prioridad de memoria: 1 = muy baja (Windows le quita paginas primero), 5 = normal
    public static bool MemPrio(int pid, int level) {
        IntPtr h = OpenProcess(0x0200, false, pid);
        if (h == IntPtr.Zero) return false;
        try { int v = level; return SetProcessInformation(h, 0, ref v, 4); }
        finally { CloseHandle(h); }
    }
}

public static class Theme {
    public static Color Bg, Side, Card, Input, Track, Text, Muted, Border, Accent, Green, Red, Amber;
}

public static class Gfx {
    public static GraphicsPath Round(Rectangle r, int rad) {
        int d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
        if (d < 1) d = 1;
        GraphicsPath p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static Color Mix(Color a, Color b, double t) {
        return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
}

public class LcCard : Panel {
    public int Radius = 12;
    public LcCard() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = Gfx.Round(r, Radius))
        {
            using (SolidBrush b = new SolidBrush(Theme.Card)) g.FillPath(b, p);
            using (Pen pen = new Pen(Theme.Border)) g.DrawPath(pen, p);
        }
    }
}

public class LcButton : Control {
    public int Radius = 8;
    public string Kind = "ghost";
    public bool Active = false;
    public bool Selected = false;
    public bool LeftAlign = false;
    public bool IsStatic = false;
    public Color SwatchColor = Color.Gray;
    private bool hover = false;

    public LcButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
        Size = new Size(100, 32);
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        bool hv = hover && Enabled && !IsStatic;
        Color fill = Color.Transparent;
        Color txt = Theme.Text;
        switch (Kind) {
            case "accent":
                fill = hv ? Gfx.Mix(Theme.Accent, Color.White, 0.15) : Theme.Accent; txt = Color.White; break;
            case "success":
                fill = hv ? Gfx.Mix(Theme.Green, Color.White, 0.12) : Theme.Green; txt = Color.White; break;
            case "danger":
                fill = hv ? Gfx.Mix(Theme.Red, Color.White, 0.12) : Theme.Red; txt = Color.White; break;
            case "nav":
                if (Active) { fill = Color.FromArgb(38, Theme.Accent); txt = Theme.Text; }
                else if (hv) { fill = Color.FromArgb(18, Theme.Text); txt = Theme.Text; }
                else { txt = Theme.Muted; }
                break;
            case "close":
                if (hv) { fill = Theme.Red; txt = Color.White; } else { txt = Theme.Muted; }
                break;
            case "swatch":
                fill = SwatchColor; break;
            default:
                fill = hv ? Gfx.Mix(Theme.Input, Theme.Text, 0.10) : Theme.Input; break;
        }
        if (!Enabled) { fill = Color.FromArgb(fill.A / 2, fill); txt = Gfx.Mix(txt, Theme.Muted, 0.6); }

        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        int rad = Math.Min(Radius, Math.Min(Width, Height) / 2);
        using (GraphicsPath p = Gfx.Round(r, rad))
        using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);

        if (Kind == "nav" && Active) {
            using (GraphicsPath ap = Gfx.Round(new Rectangle(0, Height / 2 - 9, 3, 18), 1))
            using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillPath(ab, ap);
        }
        if (Selected) {
            Rectangle rr = new Rectangle(1, 1, Width - 3, Height - 3);
            using (GraphicsPath rp = Gfx.Round(rr, Math.Max(1, rad - 1)))
            using (Pen pen = new Pen(Theme.Text, 2f)) g.DrawPath(pen, rp);
        }
        if (!string.IsNullOrEmpty(Text) && Kind != "swatch") {
            TextFormatFlags f = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            Rectangle tr = ClientRectangle;
            if (LeftAlign) { f |= TextFormatFlags.Left; tr = new Rectangle(18, 0, Width - 22, Height); }
            else { f |= TextFormatFlags.HorizontalCenter; }
            TextRenderer.DrawText(g, Text, Font, tr, txt, f);
        }
    }
}

public class LcAvatar : Control {
    public Image Photo = null;
    public string Initial = "R";
    public LcAvatar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
        Size = new Size(36, 36);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = new GraphicsPath())
        {
            p.AddEllipse(r);
            if (Photo != null) {
                GraphicsState st = g.Save();
                g.SetClip(p);
                g.DrawImage(Photo, new Rectangle(0, 0, Width, Height));
                g.Restore(st);
            } else {
                using (SolidBrush b = new SolidBrush(Theme.Accent)) g.FillPath(b, p);
                TextRenderer.DrawText(g, Initial, Font, ClientRectangle, Color.White,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
            using (Pen pen = new Pen(Theme.Border, 1f)) g.DrawPath(pen, p);
        }
    }
}

public class LcToggle : Control {
    private bool isOn = false;
    public event EventHandler CheckedChanged;
    public bool Checked {
        get { return isOn; }
        set {
            if (isOn != value) {
                isOn = value; Invalidate();
                if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
            }
        }
    }
    public LcToggle() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
        Size = new Size(46, 24);
    }
    protected override void OnClick(EventArgs e) { if (Enabled) Checked = !Checked; base.OnClick(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        Color track = isOn ? Theme.Accent : Theme.Track;
        if (!Enabled) track = Color.FromArgb(110, track);
        using (GraphicsPath p = Gfx.Round(r, r.Height / 2))
        using (SolidBrush b = new SolidBrush(track)) g.FillPath(b, p);
        int d = r.Height - 6;
        int x = isOn ? r.Right - d - 3 : 3;
        using (SolidBrush kb = new SolidBrush(Color.White)) g.FillEllipse(kb, x, 3, d, d);
    }
}

public class LcBar : Control {
    public double Value = 0;
    public Color BarColor = Color.Green;
    public LcBar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Size = new Size(200, 10);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = Gfx.Round(r, Height / 2))
        using (SolidBrush b = new SolidBrush(Theme.Track)) g.FillPath(b, p);
        double v = Value < 0 ? 0 : (Value > 1 ? 1 : Value);
        int fw = (int)((Width - 1) * v);
        if (fw >= 4) {
            Rectangle fr = new Rectangle(0, 0, fw, Height - 1);
            using (GraphicsPath fp = Gfx.Round(fr, Height / 2))
            using (SolidBrush fb = new SolidBrush(BarColor)) g.FillPath(fb, fp);
        }
    }
}

public class LcSpark : Control {
    public double[] Data = new double[0];
    public double Limit = 0;
    public Color LineColor = Color.Gray;
    public LcSpark() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Size = new Size(200, 30);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath bgp = Gfx.Round(r, 6))
        using (SolidBrush bb = new SolidBrush(Theme.Input)) g.FillPath(bb, bgp);
        if (Data == null || Data.Length < 2) return;
        double max = Limit;
        foreach (double v in Data) { if (v > max) max = v; }
        if (max <= 0) return;
        max = max * 1.1;
        int n = Data.Length;
        if (n > 60) n = 60;
        int off = Data.Length - n;
        float w = Width - 9;
        float h = Height - 9;
        PointF[] pts = new PointF[n];
        for (int i = 0; i < n; i++) {
            float x = 4 + w * (60 - n + i) / 59f;
            float y = 4 + h - (float)(Data[off + i] / max) * h;
            pts[i] = new PointF(x, y);
        }
        if (Limit > 0) {
            float ly = 4 + h - (float)(Limit / max) * h;
            using (Pen lp = new Pen(Color.FromArgb(120, Theme.Muted), 1f)) {
                lp.DashStyle = DashStyle.Dash;
                g.DrawLine(lp, 4f, ly, (float)(Width - 5), ly);
            }
        }
        PointF[] poly = new PointF[n + 2];
        for (int i = 0; i < n; i++) poly[i] = pts[i];
        poly[n] = new PointF(pts[n - 1].X, 4 + h);
        poly[n + 1] = new PointF(pts[0].X, 4 + h);
        using (SolidBrush fb = new SolidBrush(Color.FromArgb(45, LineColor))) g.FillPolygon(fb, poly);
        using (Pen pen = new Pen(LineColor, 1.6f)) g.DrawLines(pen, pts);
    }
}

// Pantalla de bienvenida: foto grande, nombre, circulo de carga y estado
public class LcSplash : Control {
    public Image Photo = null;
    public string Initial = "R";
    public string Title = "RAMLIMITER";
    public string Status = "";
    public string Info = "";
    public float Angle = 0f;
    public double Progress = 0;
    private static Font fTitle = new Font("Segoe UI Semibold", 20f);
    private static Font fStat = new Font("Segoe UI", 10f);
    private static Font fInfo = new Font("Segoe UI", 9f);
    private static Font fInit = new Font("Segoe UI Semibold", 56f);

    public LcSplash() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        using (SolidBrush bg = new SolidBrush(Theme.Bg)) g.FillRectangle(bg, ClientRectangle);

        int d = 168;
        int cx = Width / 2;
        int top = 46;
        Rectangle ar = new Rectangle(cx - d / 2, top, d, d);

        // resplandor que "respira"
        double pulse = 0.5 + 0.5 * Math.Sin(Angle * Math.PI / 180.0);
        int gr = d / 2 + 40;
        using (GraphicsPath gp = new GraphicsPath()) {
            gp.AddEllipse(new Rectangle(cx - gr, top + d / 2 - gr, gr * 2, gr * 2));
            using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                pg.CenterColor = Color.FromArgb((int)(60 + 60 * pulse), Theme.Accent);
                pg.SurroundColors = new Color[] { Color.FromArgb(0, Theme.Accent) };
                g.FillPath(pg, gp);
            }
        }

        // foto (o inicial) en circulo
        using (GraphicsPath p = new GraphicsPath()) {
            p.AddEllipse(ar);
            if (Photo != null) {
                GraphicsState st = g.Save();
                g.SetClip(p);
                g.DrawImage(Photo, ar);
                g.Restore(st);
            } else {
                using (SolidBrush b = new SolidBrush(Theme.Accent)) g.FillPath(b, p);
                TextRenderer.DrawText(g, Initial, fInit, ar, Color.White,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
        }
        using (Pen ring = new Pen(Color.FromArgb(210, Theme.Accent), 3f))
            g.DrawEllipse(ring, ar.X - 7, ar.Y - 7, d + 14, d + 14);

        // nombre
        TextRenderer.DrawText(g, Title, fTitle, new Rectangle(0, top + d + 24, Width, 36), Theme.Text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);

        // circulo de carga
        int sy = Height - 112;
        int rr = 20;
        Rectangle sr = new Rectangle(cx - rr, sy - rr, rr * 2, rr * 2);
        using (Pen tp = new Pen(Theme.Track, 4f)) g.DrawEllipse(tp, sr);
        using (Pen sp = new Pen(Theme.Accent, 4f)) {
            sp.StartCap = LineCap.Round; sp.EndCap = LineCap.Round;
            g.DrawArc(sp, sr, Angle, 100f);
        }

        // estado e info
        TextRenderer.DrawText(g, Status, fStat, new Rectangle(0, Height - 82, Width, 22), Theme.Text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, Info, fInfo, new Rectangle(0, Height - 58, Width, 20), Theme.Muted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

        // barra de progreso fina
        int bw = 220; int bx = cx - bw / 2; int by = Height - 30;
        using (GraphicsPath tp2 = Gfx.Round(new Rectangle(bx, by, bw, 5), 2))
        using (SolidBrush tb = new SolidBrush(Theme.Track)) g.FillPath(tb, tp2);
        int fw = (int)(bw * Math.Min(1.0, Progress));
        if (fw >= 4) {
            using (GraphicsPath fp2 = Gfx.Round(new Rectangle(bx, by, fw, 5), 2))
            using (SolidBrush fb2 = new SolidBrush(Theme.Accent)) g.FillPath(fb2, fp2);
        }
    }
}
'@
}

# ---------- Configuracion ----------
$MaxApps    = 12
$ConfigDir  = Join-Path $env:APPDATA 'ProcessRamLimiter'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$LogPath    = Join-Path $ConfigDir 'limiter.log'
$HistPath   = Join-Path $ConfigDir 'history.json'
$AvatarPath = Join-Path $ConfigDir 'avatar.png'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$null = New-Item -Path $ConfigDir -ItemType Directory -Force

function Get-IntOr($v, [int]$d) { if ($null -ne $v -and "$v" -ne '') { return [int]$v } else { return $d } }
function New-AppCfg($name, $ram, $cpu) {
    [pscustomobject]@{ ProcessName = [string]$name; LimitMB = (Get-IntOr $ram 1000); CpuLimit = (Get-IntOr $cpu 0) }
}

$Config = [pscustomobject]@{
    Profiles      = @( [pscustomobject]@{ Name = 'Principal'; Apps = @( (New-AppCfg 'brave' 600 0) ) } )
    ActiveProfile = 'Principal'
    IntervalSec   = 5
    KillHeaviest  = $false
    Enabled       = $false
    Autostart     = $false
    Notify        = $true
    Theme         = 'Medianoche'
    Accent        = 'Azul'
    AccentCustom  = '59,130,246'
    FontScale     = 1.0
    UserName      = 'RAMLIMITER'
    Splash        = $true
    SplashSec     = 5
    BlockEnabled  = $true
    AutoClean     = $true
    CleanThreshold = 85
    HardCap       = $false
    Blocked       = @()
    UserImportant = @()
    UserUnneeded  = @()
}
if (Test-Path $ConfigPath) {
    try {
        $loaded = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($name in @($Config.PSObject.Properties.Name)) {
            if ($name -eq 'Profiles') { continue }
            if ($null -ne $loaded.$name) { $Config.$name = $loaded.$name }
        }
        if ($loaded.Profiles) {
            $plist = @()
            foreach ($pr in @($loaded.Profiles)) {
                if (-not $pr.Name) { continue }
                $apps = @()
                foreach ($a in @($pr.Apps)) {
                    if ($a -and $a.ProcessName) { $apps += (New-AppCfg $a.ProcessName $a.LimitMB $a.CpuLimit) }
                }
                $plist += [pscustomobject]@{ Name = [string]$pr.Name; Apps = $apps }
            }
            if ($plist.Count -gt 0) { $Config.Profiles = $plist }
        } else {
            # Migracion desde versiones anteriores (1 o 3 apps)
            $apps = @()
            if ($loaded.Apps) {
                foreach ($a in @($loaded.Apps)) {
                    if ($a -and $a.ProcessName) { $apps += (New-AppCfg $a.ProcessName $a.LimitMB 0) }
                }
            } elseif ($loaded.ProcessName) {
                $apps += (New-AppCfg $loaded.ProcessName $loaded.LimitMB 0)
            }
            if ($apps.Count -gt 0) { $Config.Profiles = @( [pscustomobject]@{ Name = 'Principal'; Apps = $apps } ) }
        }
    } catch {}
}
if (-not (@($Config.Profiles) | Where-Object { $_.Name -eq $Config.ActiveProfile })) {
    $Config.ActiveProfile = [string]@($Config.Profiles)[0].Name
}

$script:Rows          = New-Object System.Collections.ArrayList
$script:RowsReady     = $false
$script:Hist          = New-Object System.Collections.ArrayList
$script:Enabled       = $false
$script:Quit          = $false
$script:BalloonShown  = $false
$script:TickN         = 0
$script:NCpu          = [Environment]::ProcessorCount
$script:CurDay        = (Get-Date).ToString('yyyy-MM-dd')
$script:ProcNames     = @()
$script:ProcFiltered  = @()
$script:SwitchingProfile = $false
$script:TrayState     = ''
$script:TrayIco       = $null
$script:AvatarBmp     = $null
$script:BaseFonts     = @{}

# Segundo plano
$script:BgAll         = @()
$script:BgRows        = @{}
$script:BgPrev        = @{}
$script:BgPrevT       = [datetime]::MinValue
$script:PathCache     = @{}
$script:BgSortCol     = 'Mb'
$script:BgSortDesc    = $true
$script:BgBusy        = $false
$script:BgPopulating  = $false
$script:BgStats       = @{ Total = 0; UnCnt = 0; UnMb = 0.0; Blk = 0 }
$script:BlockLog      = @{}
$script:BlockKills    = 0
$script:SelfNames     = @('powershell', 'pwsh', 'powershell_ise', $HostName.ToLowerInvariant())

$script:Cleaning      = $false
$script:LastAutoClean = [datetime]::MinValue

# Splash
$script:UseSplash     = $false
$script:SplashForm    = $null
$script:SplashCtl     = $null
$script:SplashTimer   = $null
$script:SplashT0      = $null
$script:SplashSec     = 5.0

function Save-Config {
    try {
        if ($script:RowsReady) { Sync-RowsToProfile }
        $nb = $Config.Notify
        if ($script:GameOn) { $Config.Notify = [bool]$script:GameNotify }
        try { $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8 } finally { $Config.Notify = $nb }
    } catch {}
}

# ---------- Temas (cambia estos numeros para crear los tuyos) ----------
function Col($a) { [System.Drawing.Color]::FromArgb([int]$a[0], [int]$a[1], [int]$a[2]) }

$Themes = @{
    'Medianoche'     = @{ Bg=@(11,13,20);  Side=@(15,17,26);  Card=@(21,24,36);  Input=@(14,16,25);  Track=@(38,42,60);  Text=@(235,238,248); Muted=@(125,132,155); Border=@(33,37,55) }
    'Grafito'        = @{ Bg=@(20,20,22);  Side=@(26,26,29);  Card=@(33,33,37);  Input=@(24,24,27);  Track=@(55,55,62);  Text=@(240,240,240); Muted=@(140,140,148); Border=@(48,48,54) }
    'Oceano'         = @{ Bg=@(8,20,28);   Side=@(10,26,36);  Card=@(14,34,46);  Input=@(8,24,34);   Track=@(28,58,74);  Text=@(226,244,250); Muted=@(110,150,165); Border=@(24,52,68) }
    'Claro'          = @{ Bg=@(240,242,247); Side=@(255,255,255); Card=@(255,255,255); Input=@(236,239,245); Track=@(218,222,232); Text=@(28,31,42); Muted=@(105,112,135); Border=@(222,226,236) }
    'Arena'          = @{ Bg=@(245,240,232); Side=@(250,246,239); Card=@(255,253,249); Input=@(240,234,224); Track=@(224,216,202); Text=@(40,34,26); Muted=@(120,110,96); Border=@(226,218,204) }
    'Alto contraste' = @{ Bg=@(0,0,0);     Side=@(0,0,0);     Card=@(10,10,10);  Input=@(0,0,0);     Track=@(80,80,80);  Text=@(255,255,255); Muted=@(205,205,205); Border=@(170,170,170) }
}
$ThemeOrder = @('Medianoche','Grafito','Oceano','Claro','Arena','Alto contraste')
$AccentList = @(
    @{ N='Azul';    C=@(59,130,246) },
    @{ N='Morado';  C=@(139,92,246) },
    @{ N='Cian';    C=@(6,182,212) },
    @{ N='Verde';   C=@(34,197,94) },
    @{ N='Rosa';    C=@(236,72,153) },
    @{ N='Naranja'; C=@(249,115,22) },
    @{ N='Rojo';    C=@(239,68,68) }
)

function Set-ThemeColors {
    $t = $Themes[[string]$Config.Theme]
    if (-not $t) { $Config.Theme = 'Medianoche'; $t = $Themes['Medianoche'] }
    $rgb = $null
    if ($Config.Accent -eq 'Personalizado') {
        $parts = ([string]$Config.AccentCustom).Split(',')
        if ($parts.Count -eq 3) { try { $rgb = @([int]$parts[0], [int]$parts[1], [int]$parts[2]) } catch { $rgb = $null } }
        if (-not $rgb) { $Config.Accent = 'Azul' }
    }
    if (-not $rgb) {
        $ac = $AccentList | Where-Object { $_.N -eq $Config.Accent } | Select-Object -First 1
        if (-not $ac) { $ac = $AccentList[0]; $Config.Accent = $ac.N }
        $rgb = $ac.C
    }
    [Theme]::Bg     = Col $t.Bg
    [Theme]::Side   = Col $t.Side
    [Theme]::Card   = Col $t.Card
    [Theme]::Input  = Col $t.Input
    [Theme]::Track  = Col $t.Track
    [Theme]::Text   = Col $t.Text
    [Theme]::Muted  = Col $t.Muted
    [Theme]::Border = Col $t.Border
    [Theme]::Accent = Col $rgb
    [Theme]::Green  = Col @(46,190,110)
    [Theme]::Red    = Col @(229,72,77)
    [Theme]::Amber  = Col @(240,173,78)
}
Set-ThemeColors

function Update-Theme($root) {
    foreach ($c in $root.Controls) {
        switch ([string]$c.Tag) {
            'bg'     { $c.BackColor = [Theme]::Bg }
            'side'   { $c.BackColor = [Theme]::Side }
            'card'   { $c.BackColor = [Theme]::Card }
            'text'   { $c.ForeColor = [Theme]::Text }
            'muted'  { $c.ForeColor = [Theme]::Muted }
            'accent' { $c.ForeColor = [Theme]::Accent }
            'border' { $c.BackColor = [Theme]::Border }
            'input'  { $c.BackColor = [Theme]::Input; $c.ForeColor = [Theme]::Text }
        }
        $c.Invalidate()
        if ($c.Controls.Count -gt 0) { Update-Theme $c }
    }
}

# Tamano de letra: guarda la fuente original de cada control y la escala
function Apply-FontScale($root) {
    $sc = [double]$Config.FontScale
    if ($sc -lt 0.8 -or $sc -gt 1.4) { $sc = 1.0 }
    foreach ($c in $root.Controls) {
        if (-not $script:BaseFonts.ContainsKey($c)) { $script:BaseFonts[$c] = $c.Font }
        $b = $script:BaseFonts[$c]
        try { $c.Font = New-Object System.Drawing.Font($b.FontFamily, [single]($b.Size * $sc), $b.Style) } catch {}
        if ($c.Controls.Count -gt 0) { Apply-FontScale $c }
    }
}
function Refresh-Look($root) { Update-Theme $root; Apply-FontScale $root }

# ---------- Fuentes ----------
$fTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$fBig    = New-Object System.Drawing.Font('Segoe UI Semibold', 22)
$fMid    = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$fH      = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$fBody   = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fSmall  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fCaps   = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)
$fBtn    = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$fLogo   = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$fMono   = New-Object System.Drawing.Font('Consolas', 9)

# ---------- Registro ----------
function Write-Log([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) { Remove-Item $LogPath -Force }
        Add-Content -Path $LogPath -Value $line
    } catch {}
    if ($txtLog) {
        $txtLog.AppendText($line + "`r`n")
        if ($txtLog.TextLength -gt 20000) { $txtLog.Text = $txtLog.Text.Substring(10000) }
    }
}

# ---------- Historial ----------
function Load-History {
    $script:Hist.Clear()
    if (-not (Test-Path $HistPath)) { return }
    try {
        $cut = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
        $raw = Get-Content $HistPath -Raw | ConvertFrom-Json
        foreach ($h in @($raw)) {
            if ($h -and $h.Date -and ([string]$h.Date -ge $cut)) {
                [void]$script:Hist.Add([pscustomobject]@{
                    Date = [string]$h.Date; App = [string]$h.App
                    Trims = [int]$h.Trims; FreedMB = [double]$h.FreedMB
                    PeakMB = [double]$h.PeakMB; Kills = [int]$h.Kills })
            }
        }
    } catch {}
}
function Save-History {
    try { ConvertTo-Json -InputObject @($script:Hist.ToArray()) -Depth 3 | Set-Content -Path $HistPath -Encoding UTF8 } catch {}
}
function Get-HistRec([string]$app) {
    $d = (Get-Date).ToString('yyyy-MM-dd')
    foreach ($h in $script:Hist) { if ($h.Date -eq $d -and $h.App -eq $app) { return $h } }
    $n = [pscustomobject]@{ Date = $d; App = $app; Trims = 0; FreedMB = 0.0; PeakMB = 0.0; Kills = 0 }
    [void]$script:Hist.Add($n)
    return $n
}
function Get-DayTotals([string]$day) {
    $t = 0; $f = 0.0; $k = 0
    foreach ($h in $script:Hist) {
        if ($h.Date -eq $day) { $t += [int]$h.Trims; $f += [double]$h.FreedMB; $k += [int]$h.Kills }
    }
    return [pscustomobject]@{ Trims = $t; FreedMB = $f; Kills = $k }
}
function Format-MB([double]$mb) {
    if ($mb -ge 1024) { return ('{0:N2} GB' -f ($mb / 1024)) }
    return ('{0:N0} MB' -f $mb)
}
function Update-TodaySummary {
    $d = (Get-Date).ToString('yyyy-MM-dd')
    $t = Get-DayTotals $d
    $txt = Format-MB $t.FreedMB
    $lblHomeSub.Text = "Hoy libere $txt   |   $($t.Trims) recortes"
    $lblStRec.Text = "$($t.Trims)"
    $lblHistToday.Text = "Hoy libere $txt"
    $lblHistSub.Text = "$($t.Trims) recortes  |  $($t.Kills) cierres"
}
function Show-DaySummary([string]$day) {
    $t = Get-DayTotals $day
    if ($t.FreedMB -le 0 -and $t.Trims -le 0) { return }
    $txt = Format-MB $t.FreedMB
    Write-Log "Resumen del $day : libere $txt ($($t.Trims) recortes, $($t.Kills) cierres)"
    if ($Config.Notify) {
        $tray.ShowBalloonTip(4000, 'RamLimiter - resumen diario', "Ayer libere $txt ($($t.Trims) recortes)", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# ---------- Autoinicio con Windows ----------
function Set-Autostart([bool]$on) {
    try {
        if ($on) {
            $psExe = (Get-Process -Id $PID).Path
            if ($IsExe) { $cmd = '"{0}" -Minimized' -f $psExe }
            else { $cmd = '"{0}" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Child -Minimized' -f $psExe, $ScriptPath }
            Set-ItemProperty -Path $RunKey -Name 'ProcessRamLimiter' -Value $cmd
        } else {
            Remove-ItemProperty -Path $RunKey -Name 'ProcessRamLimiter' -ErrorAction SilentlyContinue
        }
    } catch { Write-Log "No se pudo cambiar el inicio con Windows: $($_.Exception.Message)" }
}

# ---------- Fabricas de controles ----------
function New-Panel($x, $y, $w, $h, $parent, $tag) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.Tag = $tag
    $parent.Controls.Add($p)
    return $p
}
function New-Card($x, $y, $w, $h, $parent) {
    $c = New-Object LcCard
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    $c.Tag = 'bg'
    $parent.Controls.Add($c)
    return $c
}
function New-Lbl($text, $x, $y, $parent, $tag, $font, [int]$w = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Font = $font
    $l.Tag = $tag
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($w -gt 0) { $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size($w, ($font.Height + 4)) } else { $l.AutoSize = $true }
    $parent.Controls.Add($l)
    return $l
}
function New-Btn($text, $kind, $x, $y, $w, $h, $parent, $font) {
    $b = New-Object LcButton
    $b.Text = $text
    $b.Kind = $kind
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    if ($font) { $b.Font = $font }
    $parent.Controls.Add($b)
    return $b
}
function New-Nud($x, $y, $w, $min, $max, $inc, $parent) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = New-Object System.Drawing.Point($x, $y)
    $n.Size = New-Object System.Drawing.Size($w, 26)
    $n.Minimum = $min; $n.Maximum = $max; $n.Increment = $inc
    $n.BorderStyle = 'FixedSingle'
    $n.Font = $fBody
    $n.Tag = 'input'
    $parent.Controls.Add($n)
    return $n
}
function New-Combo($x, $y, $w, $parent, $style) {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = New-Object System.Drawing.Point($x, $y)
    $cb.Size = New-Object System.Drawing.Size($w, 26)
    $cb.DropDownStyle = $style
    $cb.FlatStyle = 'Flat'
    $cb.Font = $fBody
    $cb.Tag = 'input'
    $parent.Controls.Add($cb)
    return $cb
}

# ListView con cabecera del color del tema (y sin parpadeo)
function Style-ListView($l) {
    try {
        $pi = $l.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $pi.SetValue($l, $true, $null)
    } catch {}
    $l.OwnerDraw = $true
    $l.Add_DrawColumnHeader({
        param($s, $e)
        $br = New-Object System.Drawing.SolidBrush([Theme]::Track)
        $e.Graphics.FillRectangle($br, $e.Bounds)
        $br.Dispose()
        $tr = New-Object System.Drawing.Rectangle(($e.Bounds.X + 8), $e.Bounds.Y, ($e.Bounds.Width - 10), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $tr, [Theme]::Muted, ([System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis, NoPadding'))
    })
    $l.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $l.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
}

# ---------- Ventana ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'RamLimiter'
$form.FormBorderStyle = 'None'
$form.ClientSize = New-Object System.Drawing.Size(840, 540)
$form.StartPosition = 'CenterScreen'
$form.Font = $fBody
$form.BackColor = [Theme]::Bg
$form.Icon = [System.Drawing.SystemIcons]::Application
$form.Add_HandleCreated({ try { [RamApi]::Round($form.Handle) } catch {} })

# ----- Barra lateral -----
$sidebar = New-Panel 0 0 220 540 $form 'side'
$avSide = New-Object LcAvatar
$avSide.Location = New-Object System.Drawing.Point(18, 18)
$avSide.Size = New-Object System.Drawing.Size(36, 36)
$avSide.Font = $fLogo
$sidebar.Controls.Add($avSide)
$lblUserName = New-Lbl 'RAMLIMITER' 62 17 $sidebar 'text' $fH 150
$lblUserName.AutoEllipsis = $true
[void](New-Lbl 'experimental' 63 38 $sidebar 'muted' $fSmall)

$navBtns = @()
$navIdx = 0
$navDefs = @(
    @('Inicio', 'Inicio'),
    @('Ajustes', 'Ajustes'),
    @('Segundo plano', 'Procesos en segundo plano'),
    @('Perfil', 'Perfil'),
    @('Historial', 'Historial'),
    @('Tema', 'Tema'),
    @('Registro', 'Registro')
)
foreach ($nd in $navDefs) {
    $b = New-Btn $nd[1] 'nav' 12 (92 + $navIdx * 44) 196 40 $sidebar $fBody
    $b.Name = $nd[0]; $b.LeftAlign = $true; $b.Radius = 10
    $b.Add_Click({ param($s, $e) Show-Page $s.Name })
    $navBtns += $b
    $navIdx++
}

# Mini medidor de RAM del sistema (barra lateral)
[void](New-Lbl 'RAM DEL SISTEMA' 20 424 $sidebar 'muted' $fCaps)
$barSideRam = New-Object LcBar
$barSideRam.Location = New-Object System.Drawing.Point(20, 444)
$barSideRam.Size = New-Object System.Drawing.Size(180, 7)
$sidebar.Controls.Add($barSideRam)
$lblSideRam = New-Lbl '-' 20 456 $sidebar 'muted' $fSmall 180

$lblSideDot = New-Lbl ([string][char]0x25CF) 20 490 $sidebar $null (New-Object System.Drawing.Font('Segoe UI', 10))
$lblSideDot.ForeColor = [System.Drawing.Color]::FromArgb(110, 116, 138)
$lblSideText = New-Lbl 'Inactivo' 40 491 $sidebar 'muted' $fBody 170

# ----- Barra superior (arrastrar / minimizar / cerrar) -----
$topbar = New-Panel 220 0 620 40 $form 'bg'
$btnMin = New-Btn '-' 'nav' 528 6 36 28 $topbar $fH
$btnMin.Radius = 8
$btnMin.Add_Click({ $form.WindowState = 'Minimized' })
$btnClose = New-Btn 'X' 'close' 570 6 36 28 $topbar $fBody
$btnClose.Radius = 8
$btnClose.Add_Click({ $form.Close() })

$dragHandler = { param($s, $e) if ($e.Button -eq 'Left') { [RamApi]::Drag($form.Handle) } }
$topbar.Add_MouseDown($dragHandler)
$sidebar.Add_MouseDown($dragHandler)

# ----- Paginas -----
$pages = @{}
foreach ($pn in 'Inicio','Ajustes','Segundo plano','Perfil','Historial','Tema','Registro') {
    $pages[$pn] = New-Panel 220 40 620 500 $form 'bg'
}

# ===== Pagina INICIO =====
$pgHome = $pages['Inicio']
[void](New-Lbl 'Inicio' 24 14 $pgHome 'text' $fTitle)
$lblHomeSub = New-Lbl 'Vigila tus aplicaciones y mantiene su RAM bajo control.' 26 52 $pgHome 'muted' $fBody 360
[void](New-Lbl 'PERFIL' 400 26 $pgHome 'muted' $fCaps)
$cmbProfHome = New-Combo 446 20 150 $pgHome 'DropDownList'

$hero = New-Card 24 84 572 260 $pgHome
$homeList = New-Panel 10 10 552 190 $hero 'card'
$homeList.AutoScroll = $true
$btnToggle = New-Btn 'ACTIVAR' 'success' 20 208 270 42 $hero $fBtn
$btnToggle.Radius = 12
$btnClean = New-Btn 'Limpieza profunda' 'ghost' 302 208 130 42 $hero $fBody
$btnClean.Radius = 12
$btnTurbo = New-Btn 'Modo Turbo' 'accent' 442 208 110 42 $hero $fBody
$btnTurbo.Radius = 12

$stDefs = @( @(24, 'ESTADO'), @(170, 'PROCESOS'), @(316, 'RECORTES HOY'), @(462, 'RAM SISTEMA') )
$stLabels = @()
foreach ($d in $stDefs) {
    $c = New-Card $d[0] 356 134 90 $pgHome
    [void](New-Lbl $d[1] 14 14 $c 'muted' $fCaps)
    $stLabels += (New-Lbl '-' 14 34 $c 'text' $fMid 112)
    if ($d[1] -eq 'RAM SISTEMA') { $lblRamSub = New-Lbl '-' 14 66 $c 'muted' $fSmall 112 }
}
$lblStEstado = $stLabels[0]; $lblStProc = $stLabels[1]; $lblStRec = $stLabels[2]; $lblRamPct = $stLabels[3]
$lblStEstado.Text = 'Inactivo'; $lblStProc.Text = '0'; $lblStRec.Text = '0'

# ===== Pagina AJUSTES =====
$pgSet = $pages['Ajustes']
$pgSet.AutoScroll = $true
[void](New-Lbl 'Ajustes' 24 14 $pgSet 'text' $fTitle)
[void](New-Lbl 'Perfiles, aplicaciones (hasta 12), limites de RAM y CPU.' 26 52 $pgSet 'muted' $fBody)

$btnElevate = New-Btn 'Abrir como administrador' 'accent' 392 12 204 30 $pgSet $fBody
$btnElevate.Visible = (-not $IsAdmin)
$cardA = New-Card 24 84 572 330 $pgSet
[void](New-Lbl 'PERFIL' 20 20 $cardA 'muted' $fCaps)
$cmbProfile = New-Combo 74 14 170 $cardA 'DropDownList'
$btnProfNew = New-Btn 'Guardar como' 'ghost' 254 12 110 30 $cardA $fSmall
$btnProfDel = New-Btn 'Borrar' 'ghost' 372 12 70 30 $cardA $fSmall

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(20, 53)
$txtSearch.Size = New-Object System.Drawing.Size(300, 24)
$txtSearch.BorderStyle = 'FixedSingle'
$txtSearch.Font = $fBody
$txtSearch.Tag = 'input'
$txtSearch.MaxLength = 60
$cardA.Controls.Add($txtSearch)
$txtSearch.Add_HandleCreated({ [void][RamApi]::SendMsgStr($txtSearch.Handle, 0x1501, 1, 'Buscar app... (Enter = agregar)') })
$btnRefresh = New-Btn 'Actualizar' 'ghost' 332 50 90 30 $cardA $fBody

[void](New-Lbl 'APLICACION' 20 92 $cardA 'muted' $fCaps)
[void](New-Lbl 'RAM (MB)' 280 92 $cardA 'muted' $fCaps)
[void](New-Lbl 'CPU % (0 = OFF)' 386 92 $cardA 'muted' $fCaps)
$rowsPanel = New-Panel 10 108 552 172 $cardA 'card'
$rowsPanel.AutoScroll = $true

$btnAddApp = New-Btn '+ Agregar app' 'accent' 20 292 130 30 $cardA $fBody
[void](New-Lbl 'REVISAR CADA (SEG)' 270 299 $cardA 'muted' $fCaps)
$nudInterval = New-Nud 430 292 110 1 3600 1 $cardA

$cardB = New-Card 24 426 572 512 $pgSet
function New-Row($y, $title, $desc) {
    [void](New-Lbl $title 20 ($y + 12) $cardB 'text' $fH)
    [void](New-Lbl $desc 20 ($y + 36) $cardB 'muted' $fSmall)
    $t = New-Object LcToggle
    $t.Location = New-Object System.Drawing.Point(506, ($y + 20))
    $cardB.Controls.Add($t)
    return $t
}
$tgKill = New-Row 0 'Cerrar proceso hijo mas pesado' 'Solo apps tipo Chromium. Puede cerrar pestanas.'
$ln1 = New-Panel 20 64 532 1 $cardB 'border'
$tgAuto = New-Row 64 'Iniciar con Windows' 'Arranca minimizado en la bandeja del sistema.'
$ln2 = New-Panel 20 128 532 1 $cardB 'border'
$tgNotify = New-Row 128 'Notificaciones' 'Avisa en la bandeja (cierres y resumen diario).'
$ln3 = New-Panel 20 192 532 1 $cardB 'border'
$tgBlock = New-Row 192 'Vigilar procesos bloqueados' 'Cierra al instante los bloqueados si intentan abrirse.'
$ln4 = New-Panel 20 256 532 1 $cardB 'border'
$tgSplash = New-Row 256 'Animacion de inicio' 'Muestra tu foto y la carga al abrir la app.'
$ln5 = New-Panel 20 320 532 1 $cardB 'border'
$tgAutoClean = New-Row 320 'Limpieza automatica de RAM' 'Limpia sola cuando la RAM pasa del umbral.'
$ln6 = New-Panel 20 384 532 1 $cardB 'border'
$tgHardCap = New-Row 384 'Tope duro de memoria (agresivo)' 'Windows limita cada app a su limite. Puede ir mas lento.'
$ln7 = New-Panel 20 448 532 1 $cardB 'border'
[void](New-Lbl 'UMBRAL DE LIMPIEZA AUTOMATICA (% RAM)' 20 472 $cardB 'muted' $fCaps)
$nudThresh = New-Nud 430 464 110 50 98 1 $cardB

# ===== Pagina SEGUNDO PLANO =====
$pgBg = $pages['Segundo plano']
[void](New-Lbl 'Procesos en segundo plano' 24 14 $pgBg 'text' $fTitle)
[void](New-Lbl 'Identifica lo que corre sin ventana, cierra lo innecesario y bloquealo.' 26 52 $pgBg 'muted' $fBody 560)

$bgStatDefs = @( @(24, 'PROCESOS'), @(170, 'INNECESARIOS'), @(316, 'RAM INNECESARIA'), @(462, 'BLOQUEADOS') )
$bgStat = @()
foreach ($bd in $bgStatDefs) {
    $bc = New-Card $bd[0] 80 134 64 $pgBg
    [void](New-Lbl $bd[1] 14 9 $bc 'muted' $fCaps)
    $bgStat += (New-Lbl '-' 14 26 $bc 'text' $fMid 112)
}

$txtBgSearch = New-Object System.Windows.Forms.TextBox
$txtBgSearch.Location = New-Object System.Drawing.Point(24, 160)
$txtBgSearch.Size = New-Object System.Drawing.Size(190, 24)
$txtBgSearch.BorderStyle = 'FixedSingle'
$txtBgSearch.Font = $fBody
$txtBgSearch.Tag = 'input'
$txtBgSearch.MaxLength = 60
$pgBg.Controls.Add($txtBgSearch)
$txtBgSearch.Add_HandleCreated({ [void][RamApi]::SendMsgStr($txtBgSearch.Handle, 0x1501, 1, 'Buscar proceso...') })
$cmbBgFilter = New-Combo 222 158 170 $pgBg 'DropDownList'
$cmbBgFilter.Items.AddRange([object[]]@('Segundo plano', 'Todos', 'Innecesarios', 'Importantes', 'Windows', 'Apps abiertas', 'Bloqueados'))
$cmbBgFilter.SelectedIndex = 0
$btnBgRefresh = New-Btn 'Actualizar' 'ghost' 400 156 90 30 $pgBg $fBody
[void](New-Lbl 'AUTO' 506 165 $pgBg 'muted' $fCaps)
$tgBgAuto = New-Object LcToggle
$tgBgAuto.Location = New-Object System.Drawing.Point(542, 160)
$tgBgAuto.Checked = $true
$pgBg.Controls.Add($tgBgAuto)

$cardBg = New-Card 24 196 572 238 $pgBg
$lvBg = New-Object System.Windows.Forms.ListView
$lvBg.Location = New-Object System.Drawing.Point(12, 10)
$lvBg.Size = New-Object System.Drawing.Size(548, 182)
$lvBg.View = 'Details'
$lvBg.FullRowSelect = $true
$lvBg.MultiSelect = $true
$lvBg.HideSelection = $false
$lvBg.GridLines = $false
$lvBg.HeaderStyle = 'Clickable'
$lvBg.BorderStyle = 'None'
$lvBg.Font = $fBody
$lvBg.Tag = 'input'
[void]$lvBg.Columns.Add('Proceso', 128)
[void]$lvBg.Columns.Add('Categoria', 80)
[void]$lvBg.Columns.Add('RAM', 70)
[void]$lvBg.Columns.Add('CPU', 50)
[void]$lvBg.Columns.Add('Inst.', 42)
[void]$lvBg.Columns.Add('Estado', 70)
[void]$lvBg.Columns.Add('Descripcion', 160)
$cardBg.Controls.Add($lvBg)
Style-ListView $lvBg
$lblBgInfo = New-Lbl 'Selecciona un proceso para ver su descripcion.' 16 198 $cardBg 'muted' $fSmall 540
$lblBgInfo.Height = 34

$btnBgClose   = New-Btn 'Cerrar' 'danger' 24 444 80 34 $pgBg $fBody
$btnBgBlock   = New-Btn 'Cerrar y bloquear' 'danger' 112 444 140 34 $pgBg $fBody
$btnBgUnblock = New-Btn 'Desbloquear' 'success' 260 444 96 34 $pgBg $fBody
$btnBgAllUn   = New-Btn 'Cerrar innecesarios' 'accent' 364 444 140 34 $pgBg $fBody
$btnBgMark    = New-Btn 'Marcar' 'ghost' 512 444 84 34 $pgBg $fBody
if ($IsAdmin) { $hintTxt = 'Modo administrador: puedes cerrar casi cualquier proceso que no sea de Windows.' }
else { $hintTxt = 'Sin permisos de administrador: algunos procesos no se podran cerrar (abre RamLimiter como administrador).' }
$lblBgHint = New-Lbl $hintTxt 26 484 $pgBg 'muted' $fSmall 570

# Menu contextual / boton Marcar
$menuBg = New-Object System.Windows.Forms.ContextMenuStrip
$miMarkImp = $menuBg.Items.Add('Marcar como importante')
$miMarkUn  = $menuBg.Items.Add('Marcar como innecesario')
$miMarkClr = $menuBg.Items.Add('Quitar marca')
[void]$menuBg.Items.Add('-')
$miOpenLoc = $menuBg.Items.Add('Abrir ubicacion del archivo')
$lvBg.ContextMenuStrip = $menuBg

# ===== Pagina PERFIL =====
$pgProf = $pages['Perfil']
[void](New-Lbl 'Perfil' 24 14 $pgProf 'text' $fTitle)
[void](New-Lbl 'Pon tu foto y tu nombre. Se ven en la barra lateral y al iniciar.' 26 52 $pgProf 'muted' $fBody)

$cardP = New-Card 24 84 572 200 $pgProf
$avBig = New-Object LcAvatar
$avBig.Location = New-Object System.Drawing.Point(24, 24)
$avBig.Size = New-Object System.Drawing.Size(96, 96)
$avBig.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 32)
$cardP.Controls.Add($avBig)
$btnPhoto = New-Btn 'Subir foto' 'accent' 144 32 140 36 $cardP $fBody
$btnPhotoDel = New-Btn 'Quitar foto' 'ghost' 294 32 130 36 $cardP $fBody
[void](New-Lbl 'Formatos: PNG, JPG, BMP o GIF. Se recorta en circulo.' 144 80 $cardP 'muted' $fSmall)
[void](New-Lbl 'NOMBRE' 24 140 $cardP 'muted' $fCaps)
$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(24, 160)
$txtName.Size = New-Object System.Drawing.Size(400, 26)
$txtName.BorderStyle = 'FixedSingle'
$txtName.Font = $fBody
$txtName.Tag = 'input'
$txtName.MaxLength = 24
$cardP.Controls.Add($txtName)
[void](New-Lbl 'Los cambios se guardan solos.' 26 298 $pgProf 'muted' $fSmall)

# ===== Pagina HISTORIAL =====
$pgHist = $pages['Historial']
[void](New-Lbl 'Historial' 24 14 $pgHist 'text' $fTitle)
[void](New-Lbl 'Recortes, RAM liberada y pico maximo por dia (ultimos 30 dias).' 26 52 $pgHist 'muted' $fBody)
$cardH1 = New-Card 24 84 572 76 $pgHist
[void](New-Lbl 'RESUMEN DE HOY' 20 12 $cardH1 'muted' $fCaps)
$lblHistToday = New-Lbl 'Hoy libere 0 MB' 20 30 $cardH1 'accent' $fMid 370
$lblHistSub = New-Lbl '0 recortes  |  0 cierres' 396 40 $cardH1 'muted' $fBody 166
$cardH2 = New-Card 24 172 572 244 $pgHist
$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(12, 12)
$lv.Size = New-Object System.Drawing.Size(548, 220)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $false
$lv.HeaderStyle = 'Nonclickable'
$lv.BorderStyle = 'None'
$lv.Font = $fBody
$lv.Tag = 'input'
[void]$lv.Columns.Add('Fecha', 90)
[void]$lv.Columns.Add('Aplicacion', 130)
[void]$lv.Columns.Add('Recortes', 80)
[void]$lv.Columns.Add('Liberado', 100)
[void]$lv.Columns.Add('Pico max.', 90)
[void]$lv.Columns.Add('Cierres', 50)
$cardH2.Controls.Add($lv)
Style-ListView $lv
$btnHistCsv = New-Btn 'Exportar CSV' 'ghost' 24 428 140 34 $pgHist $fBody
$btnHistClear = New-Btn 'Borrar historial' 'ghost' 174 428 150 34 $pgHist $fBody

# ===== Pagina TEMA =====
$pgTheme = $pages['Tema']
[void](New-Lbl 'Tema' 24 14 $pgTheme 'text' $fTitle)
[void](New-Lbl 'Personaliza los colores y el tamano de letra.' 26 52 $pgTheme 'muted' $fBody)

$cardT1 = New-Card 24 84 572 124 $pgTheme
[void](New-Lbl 'COLOR DE ACENTO' 20 14 $cardT1 'muted' $fCaps)
$swatches = @{}
$tipAcc = New-Object System.Windows.Forms.ToolTip
$sx = 20
foreach ($a in $AccentList) {
    $b = New-Btn '' 'swatch' $sx 42 36 36 $cardT1 $fBody
    $b.Radius = 18
    $b.SwatchColor = Col $a.C
    $b.Name = $a.N
    $tipAcc.SetToolTip($b, $a.N)
    $b.Add_Click({ param($s, $e) $Config.Accent = $s.Name; Save-Config; Set-AppTheme })
    $swatches[$a.N] = $b
    $sx += 50
}
$btnCustomColor = New-Btn 'Otro...' 'ghost' 372 42 100 36 $cardT1 $fBody
$btnCustomColor.Radius = 18
$lblAccentName = New-Lbl 'Acento: Azul' 20 90 $cardT1 'muted' $fSmall

$cardT2 = New-Card 24 222 572 108 $pgTheme
[void](New-Lbl 'FONDO' 20 14 $cardT2 'muted' $fCaps)
$chips = @{}
$cx = 20
foreach ($tn in $ThemeOrder) {
    $b = New-Btn $tn 'ghost' $cx 44 86 40 $cardT2 $fSmall
    $b.Name = $tn; $b.Radius = 10
    $b.Add_Click({ param($s, $e) $Config.Theme = $s.Name; Save-Config; Set-AppTheme })
    $chips[$tn] = $b
    $cx += 91
}

$cardT3 = New-Card 24 344 572 96 $pgTheme
[void](New-Lbl 'TAMANO DE LETRA' 20 14 $cardT3 'muted' $fCaps)
$fontChips = @{}
$fx = 20
foreach ($pct in 90, 100, 110, 120) {
    $b = New-Btn "$pct%" 'ghost' $fx 44 104 36 $cardT3 $fBody
    $b.Name = "$pct"; $b.Radius = 10
    $b.Add_Click({ param($s, $e) $Config.FontScale = ([double]$s.Name) / 100; Save-Config; Apply-FontScale $form; Set-AppTheme })
    $fontChips[$pct] = $b
    $fx += 110
}
[void](New-Lbl 'Los cambios se aplican al instante y se guardan solos. El diseno esta ajustado para 100%.' 26 454 $pgTheme 'muted' $fSmall)

# ===== Pagina REGISTRO =====
$pgLog = $pages['Registro']
[void](New-Lbl 'Registro' 24 14 $pgLog 'text' $fTitle)
[void](New-Lbl 'Actividad reciente de la aplicacion.' 26 52 $pgLog 'muted' $fBody)
$cardL = New-Card 24 84 572 330 $pgLog
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 16)
$txtLog.Size = New-Object System.Drawing.Size(540, 298)
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.BorderStyle = 'None'
$txtLog.Font = $fMono
$txtLog.Tag = 'input'
$cardL.Controls.Add($txtLog)
$btnClear = New-Btn 'Limpiar' 'ghost' 24 428 100 34 $pgLog $fBody
$btnClear.Add_Click({ $txtLog.Clear() })
$btnFolder = New-Btn 'Carpeta de datos' 'ghost' 134 428 150 34 $pgLog $fBody
$btnFolder.Add_Click({ Start-Process explorer.exe $ConfigDir })
$btnExpTxt = New-Btn 'Exportar .txt' 'ghost' 294 428 130 34 $pgLog $fBody
$btnExpCsv = New-Btn 'Exportar .csv' 'ghost' 434 428 130 34 $pgLog $fBody

# ---------- Bandeja del sistema ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = 'RamLimiter: desactivado'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen    = $menu.Items.Add('Abrir ventana')
$miToggle  = $menu.Items.Add('Activar')
$miSummary = $menu.Items.Add('Resumen de hoy')
$miClean   = $menu.Items.Add('Limpieza profunda de RAM')
$miTurbo   = $menu.Items.Add('Modo Turbo')
$miBgTray  = $menu.Items.Add('Procesos en segundo plano')
[void]$menu.Items.Add('-')
$miExit    = $menu.Items.Add('Salir')
$tray.ContextMenuStrip = $menu

# ---------- Icono de bandeja que cambia de color ----------
function Set-TrayState([string]$state) {
    if ($script:TrayState -eq $state) { return }
    $script:TrayState = $state
    if ($state -eq 'green') { $c = [Theme]::Green }
    elseif ($state -eq 'amber') { $c = [Theme]::Amber }
    elseif ($state -eq 'red') { $c = [Theme]::Red }
    else { $c = [System.Drawing.Color]::FromArgb(120, 126, 148) }
    try {
        $bmp = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $br = New-Object System.Drawing.SolidBrush($c)
        $g.FillEllipse($br, 2, 2, 27, 27)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170, 255, 255, 255), 2)
        $g.DrawEllipse($pen, 2, 2, 27, 27)
        $g.Dispose(); $br.Dispose(); $pen.Dispose()
        $h = $bmp.GetHicon()
        $bmp.Dispose()
        $ico = [System.Drawing.Icon]::FromHandle($h)
        $old = $script:TrayIco
        $tray.Icon = $ico
        $script:TrayIco = $ico
        if ($old) { [void][RamApi]::DestroyIcon($old.Handle); $old.Dispose() }
    } catch {}
}

# ---------- Filas de aplicaciones (Ajustes + Inicio) ----------
function Get-RowName($r) {
    $n = ($r.Combo.Text.Trim()) -replace '\.exe$', ''
    if ([string]::IsNullOrWhiteSpace($n) -or $n -notmatch '^[\w\.\- ]+$') { return '' }
    return $n
}

function Layout-Rows {
    $rowsPanel.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    $homeList.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    $i = 0
    foreach ($r in $script:Rows) {
        $ry = 6 + $i * 40
        $r.Combo.Top = $ry; $r.Ram.Top = $ry; $r.Cpu.Top = $ry; $r.Del.Top = $ry
        $r.HPanel.Top = 4 + $i * 76
        $i++
    }
}

function Add-AppRow([string]$name, $ram, $cpu, [bool]$look) {
    if ($script:Rows.Count -ge $MaxApps) {
        [void][System.Windows.Forms.MessageBox]::Show("Maximo $MaxApps aplicaciones por perfil.", 'RamLimiter')
        return $null
    }
    $i = $script:Rows.Count
    $ry = 6 + $i * 40
    $en = -not $script:Enabled

    $cb = New-Combo 10 $ry 250 $rowsPanel 'DropDown'
    if ($script:ProcFiltered.Count -gt 0) { $cb.Items.AddRange([object[]]$script:ProcFiltered) }
    $cb.Text = $name
    $nr = New-Nud 270 $ry 96 50 65536 50 $rowsPanel
    $nr.Value = [decimal][math]::Min([math]::Max((Get-IntOr $ram 1000), 50), 65536)
    $nc = New-Nud 376 $ry 66 0 100 5 $rowsPanel
    $nc.Value = [decimal][math]::Min([math]::Max((Get-IntOr $cpu 0), 0), 100)
    $del = New-Btn 'X' 'close' 452 $ry 32 26 $rowsPanel $fBody
    $del.Radius = 8
    foreach ($c in @($cb, $nr, $nc, $del)) { $c.Enabled = $en }

    $hp = New-Panel 10 (4 + $i * 76) 512 72 $homeList 'card'
    $hp.BackColor = [Theme]::Card
    $hn = New-Lbl 'Libre' 0 0 $hp 'text' $fH 210
    $hu = New-Lbl '-' 214 3 $hp 'muted' $fSmall 298
    $hu.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $hb = New-Object LcBar
    $hb.Location = New-Object System.Drawing.Point(0, 26)
    $hb.Size = New-Object System.Drawing.Size(512, 6)
    $hp.Controls.Add($hb)
    $hs = New-Object LcSpark
    $hs.Location = New-Object System.Drawing.Point(0, 38)
    $hs.Size = New-Object System.Drawing.Size(512, 32)
    $hp.Controls.Add($hs)

    $row = [pscustomobject]@{
        Combo = $cb; Ram = $nr; Cpu = $nc; Del = $del
        HPanel = $hp; HName = $hn; HUsage = $hu; HBar = $hb; HSpark = $hs
        Samples = (New-Object System.Collections.ArrayList)
        LastKill = [datetime]::MinValue; Warned = $false
        CpuSec = 0.0; CpuTime = [datetime]::MinValue
        LowPrio = $false; LastMB = 0.0; LastName = ''; MemLow = $false; Capped = $false
    }
    [void]$script:Rows.Add($row)

    $del.Add_Click({ Remove-AppRow $row }.GetNewClosure())
    $cb.Add_TextChanged({ Sync-Home })
    $cb.Add_Leave({ Save-Config })
    $nr.Add_ValueChanged({ Invoke-Check })
    $nr.Add_Leave({ Save-Config })
    $nc.Add_Leave({ Save-Config })

    if ($look) {
        Refresh-Look $rowsPanel
        Refresh-Look $homeList
        Sync-Home
    }
    return $row
}

function Remove-RowControls($row) {
    Restore-Priority $row
    foreach ($c in @($row.Combo, $row.Ram, $row.Cpu, $row.Del)) {
        $rowsPanel.Controls.Remove($c)
        $script:BaseFonts.Remove($c)
        $c.Dispose()
    }
    $homeList.Controls.Remove($row.HPanel)
    $row.HPanel.Dispose()
}

function Remove-AppRow($row) {
    if ($script:Enabled) { return }
    Remove-RowControls $row
    $script:Rows.Remove($row)
    if ($script:Rows.Count -eq 0) { [void](Add-AppRow '' 1000 0 $false) }
    Layout-Rows
    Refresh-Look $rowsPanel
    Refresh-Look $homeList
    Save-Config
    Sync-Home
    Invoke-Check
}

function Get-RowApps {
    $apps = @()
    foreach ($r in $script:Rows) {
        $n = Get-RowName $r
        if ($n) { $apps += (New-AppCfg $n ([int]$r.Ram.Value) ([int]$r.Cpu.Value)) }
    }
    return $apps
}

function Sync-RowsToProfile {
    $prof = @($Config.Profiles) | Where-Object { $_.Name -eq $Config.ActiveProfile } | Select-Object -First 1
    if (-not $prof) { return }
    $prof.Apps = @(Get-RowApps)
}

function Load-Profile([string]$pname) {
    $prof = @($Config.Profiles) | Where-Object { $_.Name -eq $pname } | Select-Object -First 1
    if (-not $prof) { $prof = @($Config.Profiles)[0] }
    $Config.ActiveProfile = [string]$prof.Name
    $script:RowsReady = $false
    foreach ($r in @($script:Rows.ToArray())) { Remove-RowControls $r }
    $script:Rows.Clear()
    $rowsPanel.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    $homeList.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    foreach ($a in @($prof.Apps)) {
        if ($a) { [void](Add-AppRow ([string]$a.ProcessName) $a.LimitMB $a.CpuLimit $false) }
    }
    if ($script:Rows.Count -eq 0) { [void](Add-AppRow '' 1000 0 $false) }
    $script:RowsReady = $true
    Refresh-Look $rowsPanel
    Refresh-Look $homeList
    Sync-Home
}

function Update-ProfileCombos {
    $script:SwitchingProfile = $true
    foreach ($cb in @($cmbProfile, $cmbProfHome)) {
        $cb.Items.Clear()
        foreach ($p in @($Config.Profiles)) { [void]$cb.Items.Add([string]$p.Name) }
        $cb.SelectedItem = [string]$Config.ActiveProfile
    }
    $script:SwitchingProfile = $false
}

function Switch-Profile([string]$pname) {
    if ($pname -eq $Config.ActiveProfile) { return }
    $was = $script:Enabled
    if ($was) { Set-Enabled $false }
    Save-Config
    Load-Profile $pname
    Update-ProfileCombos
    Save-Config
    Write-Log "Perfil activo: $pname"
    Invoke-Check
    if ($was) { Set-Enabled $true }
}

# ---------- Lista de procesos (A-Z) y buscador ----------
function Update-ProcessList {
    $script:ProcNames = @(Get-Process | Group-Object Name | ForEach-Object { $_.Name } | Sort-Object)
    Apply-ProcFilter
}

function Apply-ProcFilter {
    $q = $txtSearch.Text.Trim()
    if ($q) {
        $pat = '*' + [System.Management.Automation.WildcardPattern]::Escape($q) + '*'
        $script:ProcFiltered = @($script:ProcNames | Where-Object { $_ -like $pat })
    } else {
        $script:ProcFiltered = @($script:ProcNames)
    }
    foreach ($r in $script:Rows) {
        $cb = $r.Combo
        $cur = $cb.Text
        $cb.BeginUpdate()
        $cb.Items.Clear()
        if ($script:ProcFiltered.Count -gt 0) { $cb.Items.AddRange([object[]]$script:ProcFiltered) }
        $cb.EndUpdate()
        $cb.Text = $cur
    }
}

function Add-SearchResult {
    $q = $txtSearch.Text.Trim()
    if (-not $q -or $script:ProcFiltered.Count -eq 0) { return }
    $pick = [string]$script:ProcFiltered[0]
    $exact = @($script:ProcFiltered | Where-Object { $_ -eq $q })
    if ($exact.Count -gt 0) { $pick = [string]$exact[0] }
    foreach ($r in $script:Rows) {
        if (-not $r.Combo.Text.Trim()) {
            $r.Combo.Text = $pick
            $txtSearch.Clear()
            return
        }
    }
    $nr = Add-AppRow $pick 1000 0 $true
    if ($nr) { $txtSearch.Clear(); $rowsPanel.ScrollControlIntoView($nr.Combo) }
}

# ---------- Perfil de usuario (foto y nombre) ----------
function Read-Avatar {
    if (-not (Test-Path $AvatarPath)) { return $null }
    try {
        $tmp = [System.Drawing.Image]::FromFile($AvatarPath)
        $bmp = New-Object System.Drawing.Bitmap($tmp)
        $tmp.Dispose()
        return $bmp
    } catch { return $null }
}

function Save-AvatarFrom([string]$src) {
    $img = [System.Drawing.Image]::FromFile($src)
    try {
        $sq = [math]::Min($img.Width, $img.Height)
        $bmp = New-Object System.Drawing.Bitmap(256, 256)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $dest = New-Object System.Drawing.Rectangle(0, 0, 256, 256)
        $sx = [int](($img.Width - $sq) / 2)
        $sy = [int](($img.Height - $sq) / 2)
        $g.DrawImage($img, $dest, $sx, $sy, $sq, $sq, [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
        $bmp.Save($AvatarPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    } finally { $img.Dispose() }
}

function Set-AvatarPhoto($bmp) {
    $old = $script:AvatarBmp
    foreach ($a in @($avSide, $avBig)) { $a.Photo = $bmp; $a.Invalidate() }
    $script:AvatarBmp = $bmp
    if ($old) { $old.Dispose() }
}

function Sync-Profile {
    $name = $txtName.Text.Trim()
    if ($name) { $lblUserName.Text = $name } else { $lblUserName.Text = 'RAMLIMITER' }
    $ini = 'R'
    if ($name) { $ini = $name.Substring(0, 1).ToUpper() }
    foreach ($a in @($avSide, $avBig)) { $a.Initial = $ini; $a.Invalidate() }
}

# ---------- Logica de monitoreo ----------
function Get-TotalMB($procs) {
    if (-not $procs -or @($procs).Count -eq 0) { return 0 }
    [math]::Round((($procs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 1)
}

function Set-RowColors($r) {
    $limit = [double]$r.Ram.Value
    $mb = [double]$r.LastMB
    $pct = 0.0
    if ($limit -gt 0) { $pct = [math]::Min($mb / $limit, 1.0) }
    if ($mb -gt $limit)   { $col = [Theme]::Red }
    elseif ($pct -gt 0.8) { $col = [Theme]::Amber }
    else                  { $col = [Theme]::Accent }
    $r.HBar.Value = $pct
    $r.HBar.BarColor = $col
    $r.HBar.Invalidate()
    $r.HSpark.LineColor = $col
    $r.HSpark.Limit = $limit
    $r.HSpark.Invalidate()
}

function Set-RowDisplay($r, [double]$mb, [int]$limit, [double]$cpu, [int]$cpuLimit, [int]$count) {
    $cpuTxt = "CPU $cpu%"
    if ($cpuLimit -gt 0) { $cpuTxt = "CPU $cpu% / $cpuLimit%" }
    $r.HUsage.Text = "$mb MB / $limit MB   |   $cpuTxt   |   $count proc."
    [void]$r.Samples.Add([double]$mb)
    if ($r.Samples.Count -gt 60) { $r.Samples.RemoveAt(0) }
    $r.HSpark.Data = [double[]]$r.Samples.ToArray()
    Set-RowColors $r
}

function Sync-Home {
    foreach ($r in $script:Rows) {
        $n = Get-RowName $r
        if ($n) {
            $r.HName.Text = $n
        } else {
            $r.HName.Text = 'Libre'
            $r.HUsage.Text = 'Sin configurar'
            $r.HBar.Value = 0
            $r.HBar.Invalidate()
            $r.Samples.Clear()
            $r.HSpark.Data = [double[]]@()
            $r.HSpark.Invalidate()
        }
    }
}

function Release-Cap($r) {
    $n = [string]$r.LastName
    if ($n) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) { [void][RamApi]::WsUncap($p.Id) }
    }
    $r.Capped = $false
}

function Restore-Priority($r) {
    if ((-not $r.LowPrio) -and (-not $r.MemLow) -and (-not $r.Capped)) { return }
    $n = Get-RowName $r
    if (-not $n) { $n = [string]$r.LastName }
    if ($n) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            if ($r.LowPrio) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal } catch {} }
            if ($r.MemLow) { [void][RamApi]::MemPrio($p.Id, 5) }
        }
    }
    if ($r.Capped) { Release-Cap $r }
    $r.LowPrio = $false
    $r.MemLow = $false
}

function Update-CpuLimit($r, $procs, [double]$cpuPct, [int]$cpuLimit, [string]$name) {
    if ($cpuPct -gt $cpuLimit) {
        foreach ($p in $procs) {
            try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        }
        if (-not $r.LowPrio) {
            $r.LowPrio = $true
            Write-Log "$name usa $cpuPct% de CPU (limite $cpuLimit%). Prioridad bajada."
        }
    } elseif ($r.LowPrio -and $cpuPct -le ($cpuLimit * 0.7)) {
        Restore-Priority $r
        Write-Log "$name bajo a $cpuPct% de CPU. Prioridad restaurada."
    }
}

function Stop-HeaviestChild([string]$procName, $r) {
    $cim = Get-CimInstance Win32_Process -Filter ("Name='{0}.exe'" -f $procName)
    $ids = @($cim | Where-Object { $_.CommandLine -match '--type=renderer' } |
             Select-Object -ExpandProperty ProcessId)
    if ($ids.Count -eq 0) {
        if (-not $r.Warned) {
            Write-Log "$procName no tiene procesos hijo tipo renderer: no se cierra nada."
            $r.Warned = $true
        }
        return $false
    }
    $victim = Get-Process -Id $ids -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
    if (-not $victim) { return $false }
    $mb = [math]::Round($victim.WorkingSet64 / 1MB, 1)
    Write-Log "CIERRE de proceso hijo de $procName PID $($victim.Id) ($mb MB)"
    try { $victim.Kill() } catch { return $false }
    if ($Config.Notify) {
        $tray.ShowBalloonTip(2000, 'RamLimiter', "Se cerro un proceso de $procName ($mb MB)", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    return $true
}

function Update-SysRam {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $tot = [double]$os.TotalVisibleMemorySize / 1048576
        $free = [double]$os.FreePhysicalMemory / 1048576
        $used = $tot - $free
        $pct = [math]::Round($used / $tot * 100)
        $lblRamPct.Text = "$pct%"
        $lblRamSub.Text = ('{0:N1} / {1:N1} GB' -f $used, $tot)
        if ($pct -ge 90)     { $lblRamPct.ForeColor = [Theme]::Red; $barSideRam.BarColor = [Theme]::Red }
        elseif ($pct -ge 75) { $lblRamPct.ForeColor = [Theme]::Amber; $barSideRam.BarColor = [Theme]::Amber }
        else                 { $lblRamPct.ForeColor = [Theme]::Text; $barSideRam.BarColor = [Theme]::Accent }
        $barSideRam.Value = $pct / 100.0
        $barSideRam.Invalidate()
        $lblSideRam.Text = ('{0:N1} / {1:N1} GB  ({2}%)' -f $used, $tot, $pct)
    } catch {}
}

function Invoke-Check {
    try {
        $script:TickN++
        $day = (Get-Date).ToString('yyyy-MM-dd')
        if ($day -ne $script:CurDay) { Show-DaySummary $script:CurDay; $script:CurDay = $day }

        $totalProcs = 0
        $worst = 0.0
        foreach ($r in @($script:Rows.ToArray())) {
            $name = Get-RowName $r
            if (-not $name) { continue }
            if ($name -ne $r.LastName) {
                $r.LastName = $name
                $r.Samples.Clear()
                $r.CpuTime = [datetime]::MinValue
                $r.LowPrio = $false
            }
            $limit = [int]$r.Ram.Value
            $cpuLimit = [int]$r.Cpu.Value
            $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
            $total = Get-TotalMB $procs
            $totalProcs += $procs.Count

            # CPU: porcentaje del total de la maquina desde la ultima revision
            $cpuNow = 0.0
            foreach ($p in $procs) { try { $cpuNow += $p.TotalProcessorTime.TotalSeconds } catch {} }
            $now = Get-Date
            $cpuPct = 0.0
            if ($r.CpuTime -ne [datetime]::MinValue) {
                $el = ($now - $r.CpuTime).TotalSeconds
                if ($el -gt 0) {
                    $dlt = $cpuNow - $r.CpuSec
                    if ($dlt -lt 0) { $dlt = 0 }
                    $cpuPct = [math]::Round($dlt / ($el * $script:NCpu) * 100, 1)
                }
            }
            $r.CpuSec = $cpuNow
            $r.CpuTime = $now

            if ($procs.Count -gt 0) {
                $rec = Get-HistRec $name
                if ($total -gt $rec.PeakMB) { $rec.PeakMB = $total }
            }

            if ($script:Enabled -and $procs.Count -gt 0) {
                if ($cpuLimit -gt 0) { Update-CpuLimit $r $procs $cpuPct $cpuLimit $name }

                # Prioridad de memoria muy baja: Windows le quita paginas a estas apps primero
                foreach ($p in $procs) { [void][RamApi]::MemPrio($p.Id, 1) }
                $r.MemLow = $true

                if ($total -gt $limit) {
                    Write-Log "$name usa $total MB (limite $limit). Recortando..."
                    $n = 0
                    foreach ($p in $procs) { if ([RamApi]::Trim($p.Id)) { $n++ } }
                    Start-Sleep -Milliseconds 500

                    $after = Get-TotalMB @(Get-Process -Name $name -ErrorAction SilentlyContinue)
                    $freed = [math]::Max(0, $total - $after)
                    $rec = Get-HistRec $name
                    $rec.Trims = [int]$rec.Trims + 1
                    $rec.FreedMB = [math]::Round([double]$rec.FreedMB + $freed, 1)
                    Save-History
                    Write-Log "$name : recortados $n procesos. Ahora: $after MB (libere $freed MB)"
                    $total = $after

                    # Tope duro: Windows obliga a cada proceso a no pasar de su parte del limite
                    if ($Config.HardCap -and $after -gt $limit -and $after -gt 0) {
                        $capN = 0
                        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                            $capB = [long][math]::Max(48MB, ([double]$p.WorkingSet64 * $limit / $after))
                            if ([RamApi]::WsCap($p.Id, $capB)) { $capN++ }
                        }
                        if ($capN -gt 0) { $r.Capped = $true; Write-Log "$name : tope duro aplicado a $capN proceso(s)" }
                    }

                    if ($Config.KillHeaviest -and $after -gt $limit) {
                        if (((Get-Date) - $r.LastKill).TotalSeconds -ge 30) {
                            if (Stop-HeaviestChild $name $r) {
                                $r.LastKill = Get-Date
                                $rec.Kills = [int]$rec.Kills + 1
                                Save-History
                            }
                        }
                    }
                }
            }

            $r.LastMB = $total
            if ($limit -gt 0) {
                $ratio = $total / $limit
                if ($ratio -gt $worst) { $worst = $ratio }
            }
            Set-RowDisplay $r $total $limit $cpuPct $cpuLimit $procs.Count
        }

        $lblStProc.Text = "$totalProcs"
        if (-not $script:Enabled) { Set-TrayState 'off' }
        elseif ($worst -gt 1.0) { Set-TrayState 'red' }
        elseif ($worst -gt 0.8) { Set-TrayState 'amber' }
        else { Set-TrayState 'green' }

        Update-SysRam
        Update-TodaySummary
        if ($Config.AutoClean -and (-not $script:Cleaning) -and ([int][RamApi]::LoadPct() -ge [int]$Config.CleanThreshold) -and (((Get-Date) - $script:LastAutoClean).TotalSeconds -ge 90)) {
            $script:LastAutoClean = Get-Date
            Write-Log "RAM del sistema al $([RamApi]::LoadPct())%: limpieza automatica"
            Invoke-CleanRam $true
        }
        if (($script:TickN % 12) -eq 0) { Save-History }
    } catch {
        Write-Log "Error: $($_.Exception.Message)"
    }
}

# ---------- Limpieza profunda de RAM (le pide a Windows que libere memoria) ----------
function Invoke-CleanRam([bool]$silent = $false) {
    if ($script:Cleaning) { return }
    $script:Cleaning = $true
    $oldCur = $form.Cursor
    if (-not $silent) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try {
        $before = [double][RamApi]::AvailMB()
        # 1) Recortar el working set de cada proceso
        $n = 0
        foreach ($p in @(Get-Process)) {
            if ($p.Id -gt 4 -and $p.Id -ne $PID) { if ([RamApi]::Trim($p.Id)) { $n++ } }
        }
        # 2) Ordenes directas al kernel (necesitan administrador)
        $deep = $false
        if ($IsAdmin) {
            if ([RamApi]::Priv('SeProfileSingleProcessPrivilege')) {
                [void][RamApi]::MemCmd(2)   # vaciar working sets de todo el sistema
                [void][RamApi]::MemCmd(3)   # escribir paginas modificadas a disco (quedan disponibles)
                [void][RamApi]::MemCmd(5)   # purgar cache de baja prioridad
                $deep = $true
            }
            if ([RamApi]::Priv('SeIncreaseQuotaPrivilege')) { try { [RamApi]::CacheTrim() } catch {} }
        }
        Start-Sleep -Milliseconds 700
        $after = [double][RamApi]::AvailMB()
        $freed = [math]::Max(0, [math]::Round($after - $before, 0))
        $rec = Get-HistRec 'Sistema (limpieza manual)'
        $rec.Trims = [int]$rec.Trims + 1
        $rec.FreedMB = [math]::Round([double]$rec.FreedMB + $freed, 1)
        Save-History
        $mode = 'parcial (sin administrador)'
        if ($deep) { $mode = 'completa' }
        Write-Log "Limpieza $mode : $n procesos recortados, disponible $before -> $after MB (+$freed MB)"
        if ($Config.Notify -and ((-not $silent) -or $freed -ge 100)) {
            $tray.ShowBalloonTip(2500, 'RamLimiter', "Limpieza $mode : +$(Format-MB $freed) disponibles", [System.Windows.Forms.ToolTipIcon]::Info)
        }
        Update-SysRam
        Update-TodaySummary
    } catch {
        Write-Log "Error en limpieza: $($_.Exception.Message)"
    } finally {
        $form.Cursor = $oldCur
        $script:Cleaning = $false
    }
}

# Modo Turbo: cierra lo innecesario y luego limpia a fondo
function Invoke-Turbo {
    try { Scan-Background } catch {}
    $list = @($script:BgRows.Values | Where-Object { $_.Cat -eq 'Innecesario' -and $_.Cnt -gt 0 })
    if ($list.Count -gt 0) {
        $mb = 0.0
        foreach ($r in $list) { $mb += [double]$r.Mb }
        $names = (($list | Select-Object -First 12 | ForEach-Object { $_.Name }) -join ', ')
        if ($list.Count -gt 12) { $names += ' ...' }
        $msg = "Modo Turbo cerrara $($list.Count) procesos innecesarios ($(Format-MB $mb)) y despues hara una limpieza profunda de RAM:`n$names`n`nContinuar?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'RamLimiter', 'YesNo', 'Question')
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($r in $list) {
            $k = Stop-ProcByName $r.Name
            if ($k -gt 0) { $rec = Get-HistRec $r.Name; $rec.Kills = [int]$rec.Kills + $k }
        }
        Write-Log "Modo Turbo: cerrados $($list.Count) procesos innecesarios ($(Format-MB $mb))"
        Start-Sleep -Milliseconds 600
    }
    Invoke-CleanRam
}

# ---------- Procesos en segundo plano: base de datos de nombres conocidos ----------
# Formato: 'nombre en minusculas' = 'W|I|U|descripcion'   (W = Windows protegido, I = importante, U = innecesario)
$ProcDb = @{
    'system'                  = 'W|Nucleo de Windows'
    'registry'                = 'W|Registro de Windows en memoria'
    'smss'                    = 'W|Administrador de sesiones'
    'csrss'                   = 'W|Subsistema de ejecucion cliente/servidor'
    'wininit'                 = 'W|Inicio de Windows'
    'winlogon'                = 'W|Inicio de sesion'
    'services'                = 'W|Administrador de servicios'
    'lsass'                   = 'W|Seguridad y autenticacion local'
    'lsaiso'                  = 'W|Aislamiento de credenciales'
    'svchost'                 = 'W|Host de servicios de Windows'
    'dwm'                     = 'W|Administrador de ventanas del escritorio'
    'fontdrvhost'             = 'W|Host de controladores de fuentes'
    'explorer'                = 'W|Escritorio, barra de tareas y explorador de archivos'
    'sihost'                  = 'W|Host de la interfaz de Windows'
    'taskhostw'               = 'W|Host de tareas de Windows'
    'runtimebroker'           = 'W|Permisos de apps de Windows'
    'conhost'                 = 'W|Host de consola'
    'audiodg'                 = 'W|Aislamiento de audio de Windows'
    'dllhost'                 = 'W|Host COM de Windows'
    'wmiprvse'                = 'W|Instrumental de administracion (WMI)'
    'spoolsv'                 = 'W|Cola de impresion'
    'memory compression'      = 'W|Compresion de memoria'
    'secure system'           = 'W|Sistema seguro de Windows'
    'smartscreen'             = 'W|Filtro SmartScreen'
    'applicationframehost'    = 'W|Marco de aplicaciones de Windows'
    'startmenuexperiencehost' = 'W|Menu Inicio'
    'shellexperiencehost'     = 'W|Experiencia de shell de Windows'
    'textinputhost'           = 'W|Teclado tactil y emojis'
    'backgroundtaskhost'      = 'W|Tareas en segundo plano de apps de Windows'
    'lockapp'                 = 'W|Pantalla de bloqueo'
    'userinit'                = 'W|Inicio de usuario'
    'dashost'                 = 'W|Asociacion de dispositivos'
    'wudfhost'                = 'W|Host de controladores de usuario'
    'taskmgr'                 = 'W|Administrador de tareas'
    'ctfmon'                  = 'I|Entrada de texto e idioma (teclado)'
    'searchindexer'           = 'I|Indexador de busqueda de Windows (usa disco)'
    'searchhost'              = 'I|Busqueda de Windows'
    'sgrmbroker'              = 'I|Proteccion del sistema (SGRM)'
    'securityhealthservice'   = 'I|Servicio de seguridad de Windows'
    'securityhealthsystray'   = 'I|Icono de seguridad de Windows'
    'msmpeng'                 = 'I|Antivirus Microsoft Defender'
    'mpdefendercoreservice'   = 'I|Servicio del antivirus Defender'
    'nissrv'                  = 'I|Proteccion de red de Defender'
    'wlanext'                 = 'I|Servicio Wi-Fi'
    'sppsvc'                  = 'I|Licencias de Windows'
    'unsecapp'                = 'I|Receptor de eventos WMI'
    'nvcontainer'             = 'I|Servicio de controladores NVIDIA'
    'nvdisplay.container'     = 'I|Panel y driver de video NVIDIA'
    'igfxem'                  = 'I|Modulo del driver grafico Intel'
    'igfxhk'                  = 'I|Teclas rapidas del driver Intel'
    'igfxtray'                = 'I|Icono del driver grafico Intel'
    'oneapp.igcc.winservice'  = 'I|Intel Graphics Command Center'
    'rtkauduservice64'        = 'I|Driver de audio Realtek'
    'ibtsiva'                 = 'I|Bluetooth Intel'
    'jhi_service'             = 'I|Servicio Intel (gestion de plataforma)'
    'lms'                     = 'I|Intel Management Engine'
    'vmms'                    = 'I|Hyper-V (maquinas virtuales)'
    'vmcompute'               = 'I|Hyper-V (computo)'
    'ravcpl64'                = 'U|Icono del gestor de audio Realtek'
    'onedrive'                = 'U|Sincronizacion de OneDrive'
    'onedrivestandaloneupdater' = 'U|Actualizador de OneDrive'
    'teams'                   = 'U|Microsoft Teams'
    'ms-teams'                = 'U|Microsoft Teams'
    'msteams'                 = 'U|Microsoft Teams'
    'skype'                   = 'U|Skype'
    'skypeapp'                = 'U|Skype'
    'skypehost'               = 'U|Skype'
    'yourphone'               = 'U|Vincular con el telefono'
    'phoneexperiencehost'     = 'U|Vincular con el telefono'
    'gamebar'                 = 'U|Xbox Game Bar'
    'gamebarftserver'         = 'U|Xbox Game Bar'
    'gamebarpresencewriter'   = 'U|Xbox Game Bar'
    'widgets'                 = 'U|Widgets de Windows (noticias y clima)'
    'widgetservice'           = 'U|Servicio de widgets de Windows'
    'cortana'                 = 'U|Asistente Cortana'
    'microsoftedgeupdate'     = 'U|Actualizador de Microsoft Edge'
    'msedgewebview2'          = 'U|WebView2 (lo usan varias apps; puede reabrirse solo)'
    'googleupdate'            = 'U|Actualizador de Google'
    'googlecrashhandler'      = 'U|Informe de errores de Google'
    'googlecrashhandler64'    = 'U|Informe de errores de Google'
    'dropbox'                 = 'U|Sincronizacion de Dropbox'
    'spotify'                 = 'U|Spotify (cierralo si no lo usas)'
    'discord'                 = 'U|Discord (cierralo si no lo usas)'
    'steam'                   = 'U|Cliente de Steam'
    'steamwebhelper'          = 'U|Interfaz web de Steam'
    'epicgameslauncher'       = 'U|Epic Games Launcher'
    'epicwebhelper'           = 'U|Interfaz web de Epic Games'
    'adobeipcbroker'          = 'U|Comunicacion de Adobe'
    'adobecollabsync'         = 'U|Sincronizacion de Adobe'
    'ccxprocess'              = 'U|Creative Cloud (proceso auxiliar)'
    'cclibrary'               = 'U|Bibliotecas de Creative Cloud'
    'creative cloud'          = 'U|Adobe Creative Cloud'
    'acrotray'                = 'U|Acrobat (icono de bandeja)'
    'jusched'                 = 'U|Actualizador de Java'
    'jucheck'                 = 'U|Comprobador de Java'
    'compattelrunner'         = 'U|Telemetria de compatibilidad de Microsoft'
    'ituneshelper'            = 'U|iTunes Helper'
    'nvsphelper64'            = 'U|Ayudante de NVIDIA Share'
    'lghub'                   = 'U|Logitech G HUB'
    'lghub_agent'             = 'U|Agente de Logitech G HUB'
    'lghub_updater'           = 'U|Actualizador de Logitech G HUB'
    'overwolf'                = 'U|Overwolf'
}

function Get-StrList($v) { return @(@($v) | Where-Object { $_ }) }

function Get-BlockedList { return @(@($Config.Blocked) | Where-Object { $_ -and $_.Name }) }
function Test-Blocked([string]$name) {
    foreach ($b in (Get-BlockedList)) { if ($b.Name -ieq $name) { return $true } }
    return $false
}
function Add-Block([string]$name, [string]$path) {
    if (Test-Blocked $name) { return }
    $Config.Blocked = @(@(Get-BlockedList) + [pscustomobject]@{ Name = $name; Path = $path })
    Save-Config
}
function Remove-Block([string]$name) {
    $Config.Blocked = @(@(Get-BlockedList) | Where-Object { $_.Name -ine $name })
    Save-Config
}

function Test-ProtectedName([string]$n) {
    $k = $n.ToLowerInvariant()
    if ($script:SelfNames -contains $k) { return $true }
    $db = $ProcDb[$k]
    if ($db -and $db.StartsWith('W|')) { return $true }
    return $false
}

# Devuelve @(categoria, descripcion)
function Get-ProcClass([string]$name, [bool]$win, [string]$path) {
    $k = $name.ToLowerInvariant()
    if ($script:SelfNames -contains $k) { return @('Windows', 'RamLimiter (este programa)') }
    $dc = ''; $dd = ''
    $db = $ProcDb[$k]
    if ($db) { $parts = $db.Split('|', 2); $dc = $parts[0]; $dd = $parts[1] }
    if ($dc -eq 'W') { return @('Windows', $dd) }
    if ((Get-StrList $Config.UserImportant) -contains $name) { return @('Importante', 'Marcado como importante por ti') }
    if ((Get-StrList $Config.UserUnneeded) -contains $name)  { return @('Innecesario', 'Marcado como innecesario por ti') }
    if ($dc -eq 'I') { return @('Importante', $dd) }
    if ($dc -eq 'U') { return @('Innecesario', $dd) }
    if ([string]::IsNullOrEmpty($path)) { return @('Windows', 'Protegido por el sistema (sin acceso)') }
    if ((-not $win) -and $path.StartsWith($env:windir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @('Windows', 'Componente de Windows')
    }
    if ($k -match 'updat|crashhandler|telemetr') { return @('Innecesario', 'Actualizador, informe de errores o telemetria') }
    if ($win) { return @('App abierta', 'Aplicacion con ventana abierta') }
    return @('Otro', 'Proceso en segundo plano de una aplicacion')
}

function Get-CatColor([string]$cat, [string]$state) {
    if ($state -eq 'Bloqueado') { return [Theme]::Muted }
    switch ($cat) {
        'Windows'     { return [Theme]::Green }
        'Importante'  { return [Theme]::Amber }
        'Innecesario' { return [Theme]::Red }
        'App abierta' { return [Theme]::Accent }
        default       { return [Theme]::Text }
    }
}

# Lee los procesos, los agrupa por nombre y los clasifica
function Scan-Background {
    $now = Get-Date
    $el = 0.0
    if ($script:BgPrevT -ne [datetime]::MinValue) { $el = ($now - $script:BgPrevT).TotalSeconds }
    $newPrev = @{}
    $rows = New-Object System.Collections.ArrayList
    $map = @{}

    foreach ($g in @(Get-Process | Group-Object Name)) {
        $name = [string]$g.Name
        if ($name -eq 'Idle') { continue }
        $key = $name.ToLowerInvariant()

        if (-not $script:PathCache.ContainsKey($key)) {
            $pth = ''
            foreach ($p in $g.Group) { try { $x = $p.Path; if ($x) { $pth = [string]$x; break } } catch {} }
            $script:PathCache[$key] = $pth
        }
        $path = [string]$script:PathCache[$key]

        $mb = 0.0; $cpuS = 0.0; $win = $false
        foreach ($p in $g.Group) {
            $mb += [double]$p.WorkingSet64 / 1MB
            try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $win = $true } } catch {}
            if ($path) { try { $cpuS += $p.TotalProcessorTime.TotalSeconds } catch {} }
        }
        $newPrev[$key] = $cpuS
        $cpu = 0.0
        if ($el -gt 0 -and $script:BgPrev.ContainsKey($key)) {
            $dl = $cpuS - [double]$script:BgPrev[$key]
            if ($dl -lt 0) { $dl = 0 }
            $cpu = [math]::Round($dl / ($el * $script:NCpu) * 100, 1)
        }

        $cl = Get-ProcClass $name $win $path
        $state = 'Activo'
        if (Test-Blocked $name) { $state = 'Bloqueado' }
        $row = [pscustomobject]@{
            Name = $name; Cat = [string]$cl[0]; Desc = [string]$cl[1]
            Mb = [math]::Round($mb, 1); Cpu = $cpu; Cnt = [int]$g.Count
            State = $state; Path = $path; Win = $win
        }
        [void]$rows.Add($row)
        $map[$key] = $row
    }

    # Bloqueados que ahora mismo estan cerrados
    foreach ($b in (Get-BlockedList)) {
        $key = ([string]$b.Name).ToLowerInvariant()
        if ($map.ContainsKey($key)) { continue }
        $cl = Get-ProcClass ([string]$b.Name) $false ([string]$b.Path)
        $row = [pscustomobject]@{
            Name = [string]$b.Name; Cat = [string]$cl[0]; Desc = [string]$cl[1]
            Mb = 0.0; Cpu = 0.0; Cnt = 0
            State = 'Bloqueado'; Path = [string]$b.Path; Win = $false
        }
        [void]$rows.Add($row)
        $map[$key] = $row
    }

    $script:BgPrev = $newPrev
    $script:BgPrevT = $now
    $script:BgAll = @($rows.ToArray())
    $script:BgRows = $map

    $un = @($script:BgAll | Where-Object { $_.Cat -eq 'Innecesario' -and $_.Cnt -gt 0 })
    $unMb = 0.0
    foreach ($u in $un) { $unMb += [double]$u.Mb }
    $script:BgStats = @{
        Total = @($script:BgAll | Where-Object { $_.Cnt -gt 0 }).Count
        UnCnt = $un.Count
        UnMb  = $unMb
        Blk   = @(Get-BlockedList).Count
    }
    $bgStat[0].Text = "$($script:BgStats.Total)"
    $bgStat[1].Text = "$($script:BgStats.UnCnt)"
    $bgStat[2].Text = (Format-MB $script:BgStats.UnMb)
    $bgStat[3].Text = "$($script:BgStats.Blk)"
}

function Test-BgFilter($r, [string]$f, [string]$q) {
    if ($q -and ($r.Name.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { return $false }
    switch ($f) {
        'Todos'         { return $true }
        'Innecesarios'  { return ($r.Cat -eq 'Innecesario') }
        'Importantes'   { return ($r.Cat -eq 'Importante') }
        'Windows'       { return ($r.Cat -eq 'Windows') }
        'Apps abiertas' { return ($r.Cat -eq 'App abierta') }
        'Bloqueados'    { return ($r.State -eq 'Bloqueado') }
        default         { return (($r.Cat -ne 'App abierta') -or ($r.State -eq 'Bloqueado')) }
    }
}

# Dibuja la lista segun filtro, busqueda y orden
function Render-BgList {
    if (-not $lvBg) { return }
    $f = [string]$cmbBgFilter.SelectedItem
    $q = $txtBgSearch.Text.Trim()
    $col = $script:BgSortCol
    $view = @($script:BgAll | Where-Object { Test-BgFilter $_ $f $q })
    $view = @($view | Sort-Object -Property @{ Expression = { $_.$col }; Descending = $script:BgSortDesc })

    $script:BgPopulating = $true
    $selNames = @{}
    foreach ($it in $lvBg.SelectedItems) { $selNames[[string]$it.Tag] = $true }
    $topName = ''
    try { if ($lvBg.TopItem) { $topName = [string]$lvBg.TopItem.Tag } } catch {}

    $lvBg.BeginUpdate()
    $lvBg.Items.Clear()
    $topIt = $null
    foreach ($r in $view) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$r.Name)
        [void]$it.SubItems.Add([string]$r.Cat)
        if ($r.Cnt -gt 0) {
            [void]$it.SubItems.Add((Format-MB $r.Mb))
            [void]$it.SubItems.Add("$($r.Cpu)%")
        } else {
            [void]$it.SubItems.Add('-')
            [void]$it.SubItems.Add('-')
        }
        [void]$it.SubItems.Add([string]$r.Cnt)
        [void]$it.SubItems.Add([string]$r.State)
        [void]$it.SubItems.Add([string]$r.Desc)
        $it.Tag = [string]$r.Name
        $it.ForeColor = (Get-CatColor $r.Cat $r.State)
        [void]$lvBg.Items.Add($it)
        if ($selNames.ContainsKey([string]$r.Name)) { $it.Selected = $true }
        if ([string]$r.Name -eq $topName) { $topIt = $it }
    }
    if ($topIt) { try { $lvBg.TopItem = $topIt } catch {} }
    $lvBg.EndUpdate()
    $script:BgPopulating = $false
    Update-BgInfo
}

function Refresh-BgList {
    if ($script:BgBusy) { return }
    $script:BgBusy = $true
    try {
        Scan-Background
        Render-BgList
    } catch {
        Write-Log "Error al leer procesos: $($_.Exception.Message)"
    } finally {
        $script:BgBusy = $false
    }
}

function Update-BgInfo {
    if ($script:BgPopulating) { return }
    $n = @($lvBg.SelectedItems).Count
    if ($n -eq 0) { $lblBgInfo.Text = 'Selecciona un proceso para ver su descripcion.'; return }
    if ($n -gt 1) { $lblBgInfo.Text = "$n procesos seleccionados."; return }
    $name = [string]$lvBg.SelectedItems[0].Tag
    $r = $script:BgRows[$name.ToLowerInvariant()]
    if (-not $r) { return }
    $p = $r.Path
    if ([string]::IsNullOrEmpty($p)) { $p = '(no disponible)' }
    $lblBgInfo.Text = "$($r.Name): $($r.Desc)`r`nRuta: $p"
}

function Get-BgSelection {
    $out = @()
    foreach ($it in $lvBg.SelectedItems) {
        $r = $script:BgRows[([string]$it.Tag).ToLowerInvariant()]
        if ($r) { $out += $r }
    }
    return $out
}

function Stop-ProcByName([string]$name) {
    $k = 0
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        try { $p.Kill(); $k++ } catch {}
    }
    return $k
}

function Invoke-BgClose([bool]$block) {
    $sel = @(Get-BgSelection)
    if ($sel.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Selecciona al menos un proceso de la lista.', 'RamLimiter')
        return
    }
    $prot = @($sel | Where-Object { $_.Cat -eq 'Windows' })
    $ok = @($sel | Where-Object { $_.Cat -ne 'Windows' })
    if ($prot.Count -gt 0) {
        $pn = (($prot | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', ')
        [void][System.Windows.Forms.MessageBox]::Show("Los procesos de Windows estan protegidos y no se cierran:`n$pn", 'RamLimiter', 'OK', 'Information')
    }
    if ($ok.Count -eq 0) { return }

    $names = (($ok | Select-Object -First 10 | ForEach-Object { $_.Name }) -join ', ')
    if ($ok.Count -gt 10) { $names += ' ...' }
    if ($block) { $msg = "Cerrar y BLOQUEAR $($ok.Count) proceso(s):`n$names`n`nNo se volveran a abrir hasta que los desbloquees." }
    else { $msg = "Cerrar $($ok.Count) proceso(s):`n$names" }
    $risky = @($ok | Where-Object { $_.Cat -eq 'Importante' -or $_.Cat -eq 'App abierta' })
    $icon = 'Question'
    if ($risky.Count -gt 0) {
        $rn = (($risky | Select-Object -First 6 | ForEach-Object { $_.Name }) -join ', ')
        $msg += "`n`nATENCION: incluye apps abiertas o procesos importantes ($rn). Puedes perder datos sin guardar o funciones del equipo."
        $icon = 'Warning'
    }
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'RamLimiter', 'YesNo', $icon)
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $done = 0; $fail = 0
    foreach ($r in $ok) {
        if ($block) { Add-Block $r.Name $r.Path }
        $n = Stop-ProcByName $r.Name
        if ($n -gt 0) {
            $done++
            $rec = Get-HistRec $r.Name
            $rec.Kills = [int]$rec.Kills + $n
            if ($block) { Write-Log "CERRADO y BLOQUEADO: $($r.Name) ($n proceso(s))" } else { Write-Log "CERRADO: $($r.Name) ($n proceso(s))" }
        } elseif ($r.Cnt -gt 0) {
            $fail++
            Write-Log "No se pudo cerrar $($r.Name) (acceso denegado: prueba como administrador)"
        } elseif ($block) {
            Write-Log "BLOQUEADO: $($r.Name)"
        }
    }
    Save-History
    if ($fail -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show("$fail proceso(s) no se pudieron cerrar (acceso denegado). Abre RamLimiter como administrador.", 'RamLimiter', 'OK', 'Warning')
    }
    Start-Sleep -Milliseconds 400
    Refresh-BgList
}

function Invoke-BgUnblock {
    $sel = @(Get-BgSelection | Where-Object { Test-Blocked $_.Name })
    if ($sel.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Selecciona procesos con estado 'Bloqueado' (puedes usar el filtro Bloqueados).", 'RamLimiter')
        return
    }
    $paths = @()
    foreach ($r in $sel) {
        $bp = ''
        foreach ($b in (Get-BlockedList)) { if ($b.Name -ieq $r.Name) { $bp = [string]$b.Path } }
        Remove-Block $r.Name
        Write-Log "DESBLOQUEADO: $($r.Name)"
        if ($bp -and (Test-Path $bp)) { $paths += $bp }
    }
    if ($paths.Count -gt 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show("Desbloqueado. Quieres abrirlo ahora?", 'RamLimiter', 'YesNo', 'Question')
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($p in $paths) {
                try { Start-Process -FilePath $p } catch { Write-Log "No se pudo abrir ${p}: $($_.Exception.Message)" }
            }
        }
    }
    Start-Sleep -Milliseconds 300
    Refresh-BgList
}

function Invoke-BgCloseUnneeded {
    $list = @($script:BgRows.Values | Where-Object { $_.Cat -eq 'Innecesario' -and $_.Cnt -gt 0 })
    if ($list.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('No hay procesos innecesarios activos ahora mismo.', 'RamLimiter')
        return
    }
    $mb = 0.0
    foreach ($r in $list) { $mb += [double]$r.Mb }
    $names = (($list | Select-Object -First 12 | ForEach-Object { $_.Name }) -join ', ')
    if ($list.Count -gt 12) { $names += ' ...' }
    $msg = "Se encontraron $($list.Count) procesos innecesarios ($(Format-MB $mb)):`n$names`n`nSI = cerrar y BLOQUEAR`nNO = solo cerrar`nCANCELAR = no hacer nada"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'RamLimiter', 'YesNoCancel', 'Question')
    if ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
    $block = ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
    foreach ($r in $list) {
        if ($block) { Add-Block $r.Name $r.Path }
        $n = Stop-ProcByName $r.Name
        if ($n -gt 0) {
            $rec = Get-HistRec $r.Name
            $rec.Kills = [int]$rec.Kills + $n
        }
    }
    Save-History
    Write-Log "Cerrados $($list.Count) procesos innecesarios ($(Format-MB $mb)). Bloqueo: $block"
    if ($Config.Notify) {
        $tray.ShowBalloonTip(2500, 'RamLimiter', "Cerrados $($list.Count) procesos innecesarios", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Start-Sleep -Milliseconds 500
    Refresh-BgList
}

function Set-BgMark([string]$kind) {
    $sel = @(Get-BgSelection | Where-Object { $_.Cat -ne 'Windows' })
    if ($sel.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Selecciona procesos (los de Windows no se pueden marcar).', 'RamLimiter')
        return
    }
    $imp = @(Get-StrList $Config.UserImportant)
    $unn = @(Get-StrList $Config.UserUnneeded)
    foreach ($r in $sel) {
        $nm = [string]$r.Name
        $imp = @($imp | Where-Object { $_ -ine $nm })
        $unn = @($unn | Where-Object { $_ -ine $nm })
        if ($kind -eq 'I') { $imp += $nm } elseif ($kind -eq 'U') { $unn += $nm }
    }
    $Config.UserImportant = $imp
    $Config.UserUnneeded = $unn
    Save-Config
    Refresh-BgList
}

# Vigilante: cierra al instante cualquier proceso bloqueado que se abra
function Invoke-BlockCheck {
    try {
        if (-not $Config.BlockEnabled) { return }
        $list = @(Get-BlockedList)
        if ($list.Count -eq 0) { return }
        $names = @($list | ForEach-Object { [string]$_.Name })
        $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { return }
        foreach ($g in @($procs | Group-Object Name)) {
            if (Test-ProtectedName $g.Name) { continue }
            $n = 0
            foreach ($p in $g.Group) {
                if ($p.Id -ne $PID) { try { $p.Kill(); $n++ } catch {} }
            }
            if ($n -gt 0) {
                $script:BlockKills += $n
                $rec = Get-HistRec $g.Name
                $rec.Kills = [int]$rec.Kills + $n
                $k = $g.Name.ToLowerInvariant()
                $last = $script:BlockLog[$k]
                if ((-not $last) -or (((Get-Date) - $last).TotalSeconds -ge 60)) {
                    $script:BlockLog[$k] = Get-Date
                    Write-Log "BLOQUEADO: se cerro $($g.Name) ($n proceso(s)) al intentar abrirse"
                    if ($Config.Notify) {
                        $tray.ShowBalloonTip(1500, 'RamLimiter', "Bloqueado: $($g.Name)", [System.Windows.Forms.ToolTipIcon]::Info)
                    }
                }
            }
        }
    } catch {}
}

function Update-HistoryView {
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $sorted = @($script:Hist | Sort-Object @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { [double]$_.FreedMB }; Descending = $true })
    foreach ($h in $sorted) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$h.Date)
        [void]$it.SubItems.Add([string]$h.App)
        [void]$it.SubItems.Add([string]$h.Trims)
        [void]$it.SubItems.Add((Format-MB ([double]$h.FreedMB)))
        [void]$it.SubItems.Add((Format-MB ([double]$h.PeakMB)))
        [void]$it.SubItems.Add([string]$h.Kills)
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    Update-TodaySummary
}

function Show-Page([string]$key) {
    foreach ($k in @($pages.Keys)) { $pages[$k].Visible = ($k -eq $key) }
    foreach ($b in $navBtns) { $b.Active = ($b.Name -eq $key); $b.Invalidate() }
    if ($key -eq 'Historial') { Update-HistoryView }
    if ($key -eq 'Segundo plano') { Refresh-BgList }
}

function Set-AppTheme {
    Set-ThemeColors
    $form.BackColor = [Theme]::Bg
    Update-Theme $form
    foreach ($k in @($swatches.Keys)) { $swatches[$k].Selected = ($k -eq $Config.Accent); $swatches[$k].Invalidate() }
    $btnCustomColor.Selected = ($Config.Accent -eq 'Personalizado'); $btnCustomColor.Invalidate()
    foreach ($k in @($chips.Keys)) { $chips[$k].Selected = ($k -eq $Config.Theme); $chips[$k].Invalidate() }
    $curPct = [int][math]::Round([double]$Config.FontScale * 100)
    foreach ($k in @($fontChips.Keys)) { $fontChips[$k].Selected = ([int]$k -eq $curPct); $fontChips[$k].Invalidate() }
    $lblAccentName.Text = "Acento: $($Config.Accent)   |   Fondo: $($Config.Theme)   |   Letra: $curPct%"
    if ($script:Enabled) { $lblStEstado.ForeColor = [Theme]::Green; $lblSideDot.ForeColor = [Theme]::Green }
    foreach ($r in $script:Rows) { Set-RowColors $r }
    if (@($script:BgAll).Count -gt 0) { Render-BgList }
    $form.Invalidate()
}

function Set-Enabled([bool]$on) {
    if ($on) {
        $count = 0
        foreach ($r in $script:Rows) {
            $raw = ($r.Combo.Text.Trim()) -replace '\.exe$', ''
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            if ($raw -notmatch '^[\w\.\- ]+$') {
                [void][System.Windows.Forms.MessageBox]::Show("El nombre '$raw' no es un proceso valido (por ejemplo: brave).", 'RamLimiter')
                return
            }
            $count++
        }
        if ($count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Elige o escribe al menos un nombre de proceso (por ejemplo: brave).', 'RamLimiter')
            return
        }
        $Config.IntervalSec = [int]$nudInterval.Value
        $timer.Interval = [int]$Config.IntervalSec * 1000
        foreach ($r in $script:Rows) { $r.Warned = $false }
    } else {
        foreach ($r in $script:Rows) { Restore-Priority $r }
    }

    $script:Enabled = $on
    $Config.Enabled = $on
    Save-Config

    foreach ($r in $script:Rows) {
        foreach ($c in @($r.Combo, $r.Ram, $r.Cpu, $r.Del)) { $c.Enabled = -not $on }
    }
    $btnAddApp.Enabled = -not $on
    $btnRefresh.Enabled = -not $on
    $txtSearch.Enabled = -not $on
    $nudInterval.Enabled = -not $on

    if ($on) {
        $names = @($script:Rows | ForEach-Object { Get-RowName $_ } | Where-Object { $_ })
        $btnToggle.Text = 'DESACTIVAR'
        $btnToggle.Kind = 'danger'
        $lblStEstado.Text = 'Activo'
        $lblStEstado.ForeColor = [Theme]::Green
        $lblSideDot.ForeColor = [Theme]::Green
        $lblSideText.Text = "Vigilando $($names.Count) app(s)"
        $miToggle.Text = 'Desactivar'
        $t = "RamLimiter: " + ($names -join ', ')
        $tray.Text = $t.Substring(0, [math]::Min(63, $t.Length))
        $detail = ($script:Rows | Where-Object { Get-RowName $_ } | ForEach-Object { "$(Get-RowName $_)=$($_.Ram.Value)MB/cpu$($_.Cpu.Value)%" }) -join ' | '
        Write-Log "ACTIVADO [$($Config.ActiveProfile)]: $detail | cada $($Config.IntervalSec) s | cerrar hijos: $($Config.KillHeaviest)"
    } else {
        $btnToggle.Text = 'ACTIVAR'
        $btnToggle.Kind = 'success'
        $lblStEstado.Text = 'Inactivo'
        $lblStEstado.ForeColor = [Theme]::Text
        $lblSideDot.ForeColor = [System.Drawing.Color]::FromArgb(110, 116, 138)
        $lblSideText.Text = 'Inactivo'
        $miToggle.Text = 'Activar'
        $tray.Text = 'RamLimiter: desactivado'
        Set-TrayState 'off'
        Write-Log 'DESACTIVADO'
    }
    $btnToggle.Invalidate()
    Sync-Home
}

function Show-Window {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

function Exit-App {
    $script:Quit = $true
    foreach ($r in $script:Rows) { Restore-Priority $r }
    Save-Config
    Save-History
    $timer.Stop()
    $bgTimer.Stop()
    $blockTimer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# ---------- Animacion de inicio (foto grande + circulo de carga) ----------
function Stop-Splash {
    try { if ($script:SplashTimer) { $script:SplashTimer.Stop(); $script:SplashTimer.Dispose() } } catch {}
    try { if ($script:SplashForm) { $script:SplashForm.Close(); $script:SplashForm.Dispose() } } catch {}
    $script:SplashTimer = $null
    $script:SplashForm = $null
    $form.Opacity = 1
    $form.Enabled = $true
    try { $form.Activate() } catch {}
}

function Step-Splash {
    try {
        $ms = ((Get-Date) - $script:SplashT0).TotalMilliseconds
        $total = $script:SplashSec * 1000
        $c = $script:SplashCtl
        $c.Angle = [single](($c.Angle + 9) % 360)
        $p = $ms / $total
        $c.Progress = [math]::Min($p, 1.0)
        if ($p -lt 0.20)     { $c.Status = 'Leyendo procesos en ejecucion...' }
        elseif ($p -lt 0.45) { $c.Status = 'Cargando perfiles y limites...' }
        elseif ($p -lt 0.70) { $c.Status = 'Revisando historial y bloqueados...' }
        elseif ($p -lt 0.92) { $c.Status = 'Analizando procesos en segundo plano...' }
        else                 { $c.Status = 'Todo listo' }
        $c.Invalidate()

        if ($ms -lt 400) {
            $script:SplashForm.Opacity = [math]::Min(1.0, $ms / 400)
        } elseif ($ms -lt $total) {
            $script:SplashForm.Opacity = 1.0
        } else {
            $t = ($ms - $total) / 450
            if ($t -ge 1) { Stop-Splash; return }
            $script:SplashForm.Opacity = 1.0 - $t
            $form.Opacity = $t
        }
    } catch { Stop-Splash }
}

function Start-Splash {
    $sec = 5.0
    try { $sec = [double]$Config.SplashSec } catch {}
    if ($sec -lt 2 -or $sec -gt 15) { $sec = 5.0 }
    $script:SplashSec = $sec

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ClientSize = New-Object System.Drawing.Size(460, 470)
    $f.StartPosition = 'CenterScreen'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = [Theme]::Bg
    $f.Opacity = 0
    $script:SplashForm = $f
    $f.Add_HandleCreated({ try { [RamApi]::Round($script:SplashForm.Handle) } catch {} })

    $c = New-Object LcSplash
    $c.Dock = 'Fill'
    $c.Photo = $script:AvatarBmp
    $c.Initial = $avSide.Initial
    $c.Title = $lblUserName.Text
    $st = $script:BgStats
    $c.Info = ('{0} procesos   |   {1} innecesarios   |   RAM {2}' -f $st.Total, $st.UnCnt, $lblRamPct.Text)
    $c.Status = 'Iniciando...'
    $script:SplashCtl = $c
    $f.Controls.Add($c)

    $script:SplashT0 = Get-Date
    $script:SplashTimer = New-Object System.Windows.Forms.Timer
    $script:SplashTimer.Interval = 25
    $script:SplashTimer.Add_Tick({ Step-Splash })
    $f.Show()
    $script:SplashTimer.Start()
}

# ---------- Eventos ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Invoke-Check })

# Actualizacion automatica de la lista de segundo plano (solo si esta a la vista)
$bgTimer = New-Object System.Windows.Forms.Timer
$bgTimer.Interval = 4000
$bgTimer.Add_Tick({
    if ($tgBgAuto.Checked -and $form.Visible -and $form.WindowState -ne 'Minimized' -and $pages['Segundo plano'].Visible) {
        Refresh-BgList
    }
})

# Vigilante de procesos bloqueados (siempre activo mientras la app corre)
$blockTimer = New-Object System.Windows.Forms.Timer
$blockTimer.Interval = 2000
$blockTimer.Add_Tick({ Invoke-BlockCheck })

$btnRefresh.Add_Click({ Update-ProcessList })
$btnAddApp.Add_Click({
    $nr = Add-AppRow '' 1000 0 $true
    if ($nr) { $rowsPanel.ScrollControlIntoView($nr.Combo) }
})
$txtSearch.Add_TextChanged({ Apply-ProcFilter })
$txtSearch.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Add-SearchResult } })
$btnToggle.Add_Click({ Set-Enabled (-not $script:Enabled) })
$btnClean.Add_Click({ Invoke-CleanRam })
$btnTurbo.Add_Click({ Invoke-Turbo })
$miToggle.Add_Click({ Set-Enabled (-not $script:Enabled) })
$miOpen.Add_Click({ Show-Window })
$miClean.Add_Click({ Invoke-CleanRam })
$miTurbo.Add_Click({ Invoke-Turbo })
$miBgTray.Add_Click({ Show-Window; Show-Page 'Segundo plano' })
$miSummary.Add_Click({
    $d = (Get-Date).ToString('yyyy-MM-dd')
    $t = Get-DayTotals $d
    $tray.ShowBalloonTip(3000, 'RamLimiter', ("Hoy libere {0} ({1} recortes)" -f (Format-MB $t.FreedMB), $t.Trims), [System.Windows.Forms.ToolTipIcon]::Info)
})
$tray.Add_DoubleClick({ Show-Window })
$miExit.Add_Click({ Exit-App })

# Segundo plano
$btnBgRefresh.Add_Click({ Refresh-BgList })
$txtBgSearch.Add_TextChanged({ Render-BgList })
$cmbBgFilter.Add_SelectedIndexChanged({ Render-BgList })
$lvBg.Add_SelectedIndexChanged({ Update-BgInfo })
$lvBg.Add_ColumnClick({
    param($s, $e)
    $map = @('Name', 'Cat', 'Mb', 'Cpu', 'Cnt', 'State', 'Desc')
    $c = $map[$e.Column]
    if ($script:BgSortCol -eq $c) {
        $script:BgSortDesc = -not $script:BgSortDesc
    } else {
        $script:BgSortCol = $c
        $script:BgSortDesc = ($c -eq 'Mb' -or $c -eq 'Cpu' -or $c -eq 'Cnt')
    }
    Render-BgList
})
$btnBgClose.Add_Click({ Invoke-BgClose $false })
$btnBgBlock.Add_Click({ Invoke-BgClose $true })
$btnBgUnblock.Add_Click({ Invoke-BgUnblock })
$btnBgAllUn.Add_Click({ Invoke-BgCloseUnneeded })
$btnBgMark.Add_Click({ $menuBg.Show($btnBgMark, (New-Object System.Drawing.Point(0, $btnBgMark.Height))) })
$miMarkImp.Add_Click({ Set-BgMark 'I' })
$miMarkUn.Add_Click({ Set-BgMark 'U' })
$miMarkClr.Add_Click({ Set-BgMark 'N' })
$miOpenLoc.Add_Click({
    $sel = @(Get-BgSelection)
    if ($sel.Count -eq 0) { return }
    $p = [string]$sel[0].Path
    if ($p -and (Test-Path $p)) { Start-Process explorer.exe ('/select,"{0}"' -f $p) }
    else { [void][System.Windows.Forms.MessageBox]::Show('No se conoce la ubicacion de ese proceso.', 'RamLimiter') }
})

# Perfiles de limites
$onProfileChanged = {
    param($s, $e)
    if ($script:SwitchingProfile) { return }
    if ($s.SelectedItem) { Switch-Profile ([string]$s.SelectedItem) }
}
$cmbProfile.Add_SelectedIndexChanged($onProfileChanged)
$cmbProfHome.Add_SelectedIndexChanged($onProfileChanged)

$btnProfNew.Add_Click({
    $nm = [Microsoft.VisualBasic.Interaction]::InputBox('Nombre del perfil (ej: Trabajo, Gaming, Ahorro). Se guardan las apps y limites actuales:', 'Guardar perfil', '')
    $nm = $nm.Trim()
    if (-not $nm) { return }
    if ($nm.Length -gt 24) { $nm = $nm.Substring(0, 24) }
    Save-Config
    $apps = @(Get-RowApps)
    $exist = @($Config.Profiles) | Where-Object { $_.Name -eq $nm } | Select-Object -First 1
    if ($exist) {
        $exist.Apps = $apps
    } else {
        $Config.Profiles = @($Config.Profiles) + [pscustomobject]@{ Name = $nm; Apps = $apps }
    }
    $Config.ActiveProfile = $nm
    Update-ProfileCombos
    Save-Config
    Write-Log "Perfil guardado: $nm"
})

$btnProfDel.Add_Click({
    if (@($Config.Profiles).Count -le 1) {
        [void][System.Windows.Forms.MessageBox]::Show('Debe existir al menos un perfil.', 'RamLimiter')
        return
    }
    $ans = [System.Windows.Forms.MessageBox]::Show("Borrar el perfil '$($Config.ActiveProfile)'?", 'RamLimiter', [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $was = $script:Enabled
    if ($was) { Set-Enabled $false }
    $gone = [string]$Config.ActiveProfile
    $Config.Profiles = @(@($Config.Profiles) | Where-Object { $_.Name -ne $gone })
    Load-Profile ([string]@($Config.Profiles)[0].Name)
    Update-ProfileCombos
    Save-Config
    Write-Log "Perfil borrado: $gone"
    Invoke-Check
    if ($was) { Set-Enabled $true }
})

# Perfil de usuario
$avSide.Add_Click({ Show-Page 'Perfil' })
$btnPhoto.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Imagenes|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
    $dlg.Title = 'Elige tu foto de perfil'
    try {
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            Save-AvatarFrom $dlg.FileName
            Set-AvatarPhoto (Read-Avatar)
            Write-Log 'Foto de perfil actualizada'
        }
    } catch { Write-Log "No se pudo cargar la foto: $($_.Exception.Message)" }
    $dlg.Dispose()
})
$btnPhotoDel.Add_Click({
    Remove-Item $AvatarPath -Force -ErrorAction SilentlyContinue
    Set-AvatarPhoto $null
})

# Tema: color libre
$btnCustomColor.Add_Click({
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    $dlg.Color = [Theme]::Accent
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $Config.AccentCustom = '{0},{1},{2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
        $Config.Accent = 'Personalizado'
        Save-Config
        Set-AppTheme
    }
    $dlg.Dispose()
})

# Historial / exportar
$btnHistCsv.Add_Click({
    if ($script:Hist.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Todavia no hay historial para exportar.', 'RamLimiter')
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'historial_ramlimiter.csv'
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:Hist | Select-Object Date, App, Trims, FreedMB, PeakMB, Kills | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
            Write-Log "Historial exportado: $($dlg.FileName)"
        } catch { Write-Log "No se pudo exportar: $($_.Exception.Message)" }
    }
    $dlg.Dispose()
})
$btnExpCsv.Add_Click({ $btnHistCsv.PerformClick() })
$btnHistClear.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show('Borrar todo el historial?', 'RamLimiter', [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:Hist.Clear()
        Save-History
        Update-HistoryView
    }
})
$btnExpTxt.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Texto (*.txt)|*.txt'
    $dlg.FileName = 'registro_ramlimiter.txt'
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            if (Test-Path $LogPath) { Copy-Item -Path $LogPath -Destination $dlg.FileName -Force }
            else { Set-Content -Path $dlg.FileName -Value $txtLog.Text -Encoding UTF8 }
            Write-Log "Registro exportado: $($dlg.FileName)"
        } catch { Write-Log "No se pudo exportar: $($_.Exception.Message)" }
    }
    $dlg.Dispose()
})

$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:Quit -and $e.CloseReason -eq 'UserClosing') {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:BalloonShown) {
            $tray.ShowBalloonTip(2500, 'RamLimiter', 'Sigue funcionando en segundo plano. Clic derecho en el icono > Salir para cerrarlo.', [System.Windows.Forms.ToolTipIcon]::Info)
            $script:BalloonShown = $true
        }
    }
})
$form.Add_Shown({
    if ($Minimized) {
        $form.Hide()
        $form.Opacity = 1
        $form.Enabled = $true
        return
    }
    if ($script:UseProfileSetup) {
        try { Show-ProfileSetup } catch { Write-Log "No se pudo mostrar la pantalla de perfil: $($_.Exception.Message)" }
    }
    if ($script:UseSplash) {
        try { Start-Splash } catch { Stop-Splash }
    } elseif ($script:UseProfileSetup) {
        Stop-Splash
    }
})

# =====================================================================
#  MEJORAS RAMLIMITER v2  (limpieza agresiva + modo ahorro + pantalla completa)
#  PEGAR TODO ESTE BLOQUE justo ANTES de la linea:
#      # ---------- Arranque ----------
# =====================================================================

# ---------- API extra de Windows ----------
if (-not ('RamApi2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RamApi2 {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    public static int ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return (int)pid; }
    public static void Corners(IntPtr h, int mode) { int v = mode; DwmSetWindowAttribute(h, 33, ref v, 4); }
}
'@
}

# Permiso para poder tocar mas procesos (solo administrador)
if ($IsAdmin) { [void][RamApi]::Priv('SeDebugPrivilege') }

# ---------- Configuracion nueva: Modo Ahorro continuo ----------
if (-not $Config.PSObject.Properties['LiteMode']) { $Config | Add-Member -NotePropertyName LiteMode -NotePropertyValue $true }
try {
    if (Test-Path $ConfigPath) {
        $jx = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($null -ne $jx.LiteMode) { $Config.LiteMode = [bool]$jx.LiteMode }
    }
} catch {}

$ln8 = New-Panel 20 512 532 1 $cardB 'border'
$tgLite = New-Row 512 'Modo Ahorro continuo (PC lenta)' 'Mantiene las apps de fondo con la minima RAM, siempre.'
$cardB.Height = 590
$tgLite.Checked = [bool]$Config.LiteMode

function Reset-AllMemPrio {
    foreach ($p in @(Get-Process)) {
        if ($p.Id -gt 4) { [void][RamApi]::MemPrio($p.Id, 5) }
    }
}

$tgLite.Add_CheckedChanged({
    $Config.LiteMode = $tgLite.Checked
    Save-Config
    if ($tgLite.Checked) { Write-Log 'Modo Ahorro continuo: ACTIVADO' }
    else { Reset-AllMemPrio; Write-Log 'Modo Ahorro continuo: DESACTIVADO' }
})

# Modo Ahorro: le dice a Windows que las apps de fondo tienen prioridad de memoria MINIMA
# (Windows les quita paginas primero) y las recorta cuando la RAM esta ocupada.
# La app que estas usando (primer plano) NO se toca, para que no se ponga lenta.
function Invoke-LiteMode {
    if ((-not $Config.LiteMode) -or $script:Cleaning) { return }
    try {
        $fgPid = [RamApi2]::ForegroundPid()
        $fgName = ''
        if ($fgPid -gt 0) {
            $fp = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
            if ($fp) { $fgName = [string]$fp.ProcessName }
        }
        $busy = ([int][RamApi]::LoadPct() -ge 55)
        $skip = @('idle', 'system', 'registry', 'memory compression', 'secure system', 'vmmem', 'vmmemwsl') + @($script:TrimSkip)
        foreach ($p in @(Get-Process)) {
            if ($p.Id -le 4 -or $p.Id -eq $PID) { continue }
            $nm = [string]$p.ProcessName
            if ($skip -contains $nm.ToLowerInvariant()) { continue }
            if ($script:GameOn -and (($p.Id -eq $script:GamePid) -or ($nm -eq $script:GameName))) { continue }
            if ($fgName -and ($nm -eq $fgName)) { [void][RamApi]::MemPrio($p.Id, 5); continue }
            [void][RamApi]::MemPrio($p.Id, 1)
            if ($busy -and ($p.WorkingSet64 -gt 25MB)) { [void][RamApi]::Trim($p.Id) }
        }
    } catch {}
}

$liteTimer = New-Object System.Windows.Forms.Timer
$liteTimer.Interval = 20000
$liteTimer.Add_Tick({ Invoke-LiteMode })
$liteTimer.Start()
$form.Add_FormClosed({ try { Reset-AllMemPrio } catch {} })

# ---------- Limpieza profunda MEJORADA (reemplaza a la anterior) ----------
# Ordenes directas a Windows: vaciar working sets, escribir paginas modificadas,
# purgar la lista standby, vaciar cache de archivos, y repetir una segunda pasada.
function Invoke-CleanRam([bool]$silent = $false) {
    if ($script:Cleaning) { return }
    if ($script:GameOn) { Apply-GamePressure $false; Write-Log 'Limpieza segura (Modo Juego activo)'; return }
    $script:Cleaning = $true
    $oldCur = $form.Cursor
    if (-not $silent) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try {
        $before = [double][RamApi]::AvailMB()
        $deep = $false
        if ($IsAdmin) {
            [void][RamApi]::Priv('SeDebugPrivilege')
            [void][RamApi]::Priv('SeIncreaseQuotaPrivilege')
            $deep = [RamApi]::Priv('SeProfileSingleProcessPrivilege')
        }

        # 1) Recortar cada proceso (dos pasadas: la 2da atrapa lo que volvio a cargarse)
        $ids = @(Get-Process | Where-Object { $_.Id -gt 4 -and $_.Id -ne $PID } | ForEach-Object { $_.Id })
        $n = 0
        foreach ($id in $ids) { if ([RamApi]::Trim($id)) { $n++ } }

        # 2) Ordenes al kernel de Windows (necesitan administrador)
        if ($deep) {
            [void][RamApi]::MemCmd(2)               # vaciar working sets de todo el sistema
            [void][RamApi]::MemCmd(3)               # escribir paginas modificadas al disco
            if ($silent) { [void][RamApi]::MemCmd(5) }   # automatica: solo cache de baja prioridad
            else { [void][RamApi]::MemCmd(4) }           # manual: purgar TODA la lista standby
            try { [RamApi]::CacheTrim() } catch {}
        }
        Start-Sleep -Milliseconds 350
        foreach ($id in $ids) { [void][RamApi]::Trim($id) }
        if ($deep) {
            [void][RamApi]::MemCmd(2)
            [void][RamApi]::MemCmd(3)
            if (-not $silent) { [void][RamApi]::MemCmd(4) }
        }
        [void][RamApi]::Trim($PID)

        Start-Sleep -Milliseconds 600
        $after = [double][RamApi]::AvailMB()
        $freed = [math]::Max(0, [math]::Round($after - $before, 0))
        $rec = Get-HistRec 'Sistema (limpieza manual)'
        $rec.Trims = [int]$rec.Trims + 1
        $rec.FreedMB = [math]::Round([double]$rec.FreedMB + $freed, 1)
        Save-History
        $mode = 'parcial (sin administrador)'
        if ($deep) { $mode = 'completa' }
        Write-Log "Limpieza $mode : $n procesos recortados, disponible $before -> $after MB (+$freed MB)"
        if ($Config.Notify -and ((-not $silent) -or $freed -ge 100)) {
            $msg = ("Libre: {0} -> {1}  (+{2})" -f (Format-MB $before), (Format-MB $after), (Format-MB $freed))
            if (-not $deep) { $msg += "`nPara limpieza completa abre RamLimiter como administrador." }
            $tray.ShowBalloonTip(4000, "RamLimiter - limpieza $mode", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        }
        Update-SysRam
        Update-TodaySummary
    } catch {
        Write-Log "Error en limpieza: $($_.Exception.Message)"
    } finally {
        $form.Cursor = $oldCur
        $script:Cleaning = $false
    }
}

# =====================================================================
#  MEJORAS RAMLIMITER v2.1 : Modo Juego/Foco + Modo mini + Actualizacion automatica
# =====================================================================
$AppVersion = '2.2.2'

# ---------- API extra: ventana a pantalla completa y memoria total ----------
if (-not ('RamApi3' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class RamApi3 {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L; public int T; public int R; public int B; }
    [StructLayout(LayoutKind.Sequential)] struct MS {
        public uint len; public uint load; public ulong tot; public ulong avail;
        public ulong pf; public ulong apf; public ulong vt; public ulong avt; public ulong ext;
    }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MS s);

    static MS Get() {
        MS s = new MS();
        s.len = (uint)Marshal.SizeOf(typeof(MS));
        GlobalMemoryStatusEx(ref s);
        return s;
    }
    public static double TotalMB() { return Get().tot / 1048576.0; }
    public static double AvailMB() { return Get().avail / 1048576.0; }
    public static int LoadPct() { return (int)Get().load; }

    // PID de la ventana en primer plano si cubre toda su pantalla; si no, 0
    public static int FullscreenPid() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero || h == GetShellWindow() || h == GetDesktopWindow()) return 0;
        RECT r;
        if (!GetWindowRect(h, out r)) return 0;
        Rectangle b = Screen.FromHandle(h).Bounds;
        if (r.L <= b.Left && r.T <= b.Top && r.R >= b.Right && r.B >= b.Bottom) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            return (int)pid;
        }
        return 0;
    }
}
'@
}

# ---------- Configuracion nueva ----------
$script:RawCfg = $null
try { if (Test-Path $ConfigPath) { $script:RawCfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } } catch {}
function Add-CfgDefault([string]$name, $default) {
    if (-not $Config.PSObject.Properties[$name]) { $Config | Add-Member -NotePropertyName $name -NotePropertyValue $default }
    try { if ($script:RawCfg -and ($null -ne $script:RawCfg.$name)) { $Config.$name = $script:RawCfg.$name } } catch {}
}
Add-CfgDefault 'GameMode' $true
Add-CfgDefault 'GameAuto' $true
Add-CfgDefault 'GameKill' $false
Add-CfgDefault 'GameApps' ''
Add-CfgDefault 'UpdateAuto' $true
Add-CfgDefault 'UpdateSilent' $false
Add-CfgDefault 'UpdateUrl' ''
Add-CfgDefault 'MiniX' (-1)
Add-CfgDefault 'MiniY' (-1)

# ---------- Estado ----------
$script:GameOn     = $false
$script:GamePid    = 0
$script:GameName   = ''
$script:GameT0     = [datetime]::MinValue
$script:GameNotify = $true
$script:GameTickN  = 0
$script:UpdVer     = ''
$script:UpdText    = ''

# Procesos que NUNCA se recortan ni se les baja la prioridad de memoria (hacerlo causa tirones)
$script:TrimSkip = @('dwm','audiodg','csrss','explorer','winlogon','lsass','sihost','ctfmon','fontdrvhost','shellexperiencehost','startmenuexperiencehost','searchhost','textinputhost','lockapp','smss','wininit','services')
# Apps a pantalla completa que NO cuentan como juego (navegadores, reproductores, presentaciones)
$script:GameExclude = @('chrome','msedge','brave','firefox','opera','opera_gx','vivaldi','iexplore','vlc','mpv','wmplayer','powerpnt','acrord32','acrobat','teams','ms-teams','zoom')
# Procesos "innecesarios" que el Modo Juego jamas cierra (launchers, overlays, voz)
$script:GameKeep = @('steam','steamwebhelper','epicgameslauncher','epicwebhelper','lghub','lghub_agent','nvcontainer','overwolf','discord')

# =====================================================================
#  AJUSTES: tarjeta nueva (Modo Juego + Actualizacion)
# =====================================================================
$cardC = New-Card 24 1028 572 504 $pgSet

function New-RowOn($card, $y, $title, $desc) {
    [void](New-Lbl $title 20 ($y + 12) $card 'text' $fH)
    [void](New-Lbl $desc 20 ($y + 36) $card 'muted' $fSmall)
    $t = New-Object LcToggle
    $t.Location = New-Object System.Drawing.Point(506, ($y + 20))
    $card.Controls.Add($t)
    return $t
}
function New-TextOn($parent, $x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 24)
    $t.BorderStyle = 'FixedSingle'
    $t.Font = $fBody
    $t.Tag = 'input'
    $t.MaxLength = 300
    $parent.Controls.Add($t)
    return $t
}

$tgGame = New-RowOn $cardC 0 'Modo Juego / Foco' 'Detecta tu juego y le da la RAM y la prioridad.'
[void](New-Panel 20 64 532 1 $cardC 'border')
$tgGameAuto = New-RowOn $cardC 64 'Detectar pantalla completa' 'Cualquier app a pantalla completa cuenta como juego.'
[void](New-Panel 20 128 532 1 $cardC 'border')
$tgGameKill = New-RowOn $cardC 128 'Cerrar innecesarios al jugar' 'Cierra los marcados como innecesarios, sin preguntar.'
[void](New-Panel 20 192 532 1 $cardC 'border')
[void](New-Lbl 'APPS DE JUEGO (separadas por coma, ej: javaw, eurotrucks2)' 20 204 $cardC 'muted' $fCaps)
$txtGameApps = New-TextOn $cardC 20 226 532
$txtGameApps.Add_HandleCreated({ [void][RamApi]::SendMsgStr($txtGameApps.Handle, 0x1501, 1, 'Nombre del proceso, sin .exe') })
[void](New-Panel 20 264 532 1 $cardC 'border')
$tgUpd = New-RowOn $cardC 264 'Actualizacion automatica' 'Busca versiones nuevas al abrir y cada 6 horas.'
[void](New-Panel 20 328 532 1 $cardC 'border')
$tgUpdSilent = New-RowOn $cardC 328 'Instalar sola, sin preguntar' 'Apagado: te avisa y tu decides cuando instalar.'
[void](New-Panel 20 392 532 1 $cardC 'border')
[void](New-Lbl 'ENLACE DE ACTUALIZACION (https://...)' 20 404 $cardC 'muted' $fCaps)
$txtUpdUrl = New-TextOn $cardC 20 426 532
$txtUpdUrl.Add_HandleCreated({ [void][RamApi]::SendMsgStr($txtUpdUrl.Handle, 0x1501, 1, 'https://raw.githubusercontent.com/usuario/repo/main/RamLimiter.ps1') })
$lblUpdStatus = New-Lbl "Version instalada: v$AppVersion" 20 466 $cardC 'muted' $fSmall 300
$btnUpdCheck = New-Btn 'Buscar ahora' 'accent' 330 458 104 30 $cardC $fSmall
$btnUpdInstall = New-Btn 'Instalar' 'success' 442 458 110 30 $cardC $fSmall
$btnUpdInstall.Visible = $false

$tgGame.Checked = [bool]$Config.GameMode
$tgGameAuto.Checked = [bool]$Config.GameAuto
$tgGameKill.Checked = [bool]$Config.GameKill
$tgUpd.Checked = [bool]$Config.UpdateAuto
$tgUpdSilent.Checked = [bool]$Config.UpdateSilent
$txtGameApps.Text = [string]$Config.GameApps
$txtUpdUrl.Text = [string]$Config.UpdateUrl

# =====================================================================
#  MODO MINI (ventanita siempre visible)
# =====================================================================
$mini = New-Object System.Windows.Forms.Form
$mini.FormBorderStyle = 'None'
$mini.ShowInTaskbar = $false
$mini.TopMost = $true
$mini.StartPosition = 'Manual'
$mini.ClientSize = New-Object System.Drawing.Size(250, 130)
$mini.BackColor = [Theme]::Bg
$mini.Font = $fBody
$mini.Add_HandleCreated({ try { [RamApi]::Round($mini.Handle) } catch {} })
$mini.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen([Theme]::Border)
    $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
    $pen.Dispose()
})

$lblMiniTitle = New-Lbl 'RAM DEL SISTEMA' 12 10 $mini 'muted' $fCaps
$lblMiniPct = New-Lbl '-' 12 24 $mini 'text' $fMid 90
$lblMiniGb = New-Lbl '-' 104 32 $mini 'muted' $fSmall 134
$lblMiniGb.TextAlign = [System.Drawing.ContentAlignment]::TopRight
$barMini = New-Object LcBar
$barMini.Location = New-Object System.Drawing.Point(12, 64)
$barMini.Size = New-Object System.Drawing.Size(226, 7)
$mini.Controls.Add($barMini)
$btnMiniClean = New-Btn 'Limpiar' 'accent' 12 78 70 28 $mini $fSmall
$btnMiniOpen = New-Btn 'Abrir' 'ghost' 88 78 66 28 $mini $fSmall
$btnMiniHide = New-Btn 'Ocultar' 'ghost' 160 78 78 28 $mini $fSmall
$lblMiniState = New-Lbl 'Modo Juego: en espera' 12 110 $mini 'muted' $fSmall 226

$miniDrag = { param($s, $e) if ($e.Button -eq 'Left') { [RamApi]::Drag($mini.Handle) } }
foreach ($c in @($mini, $lblMiniTitle, $lblMiniPct, $lblMiniGb, $lblMiniState)) { $c.Add_MouseDown($miniDrag) }

function Update-Mini {
    try {
        $pct = [int][RamApi3]::LoadPct()
        $tot = [RamApi3]::TotalMB()
        $av = [RamApi3]::AvailMB()
        $lblMiniPct.Text = "$pct%"
        $lblMiniGb.Text = ('{0:N1} libres de {1:N1} GB' -f ($av / 1024), ($tot / 1024))
        $barMini.Value = $pct / 100.0
        if ($pct -ge 90) { $barMini.BarColor = [Theme]::Red; $lblMiniPct.ForeColor = [Theme]::Red }
        elseif ($pct -ge 75) { $barMini.BarColor = [Theme]::Amber; $lblMiniPct.ForeColor = [Theme]::Amber }
        else { $barMini.BarColor = [Theme]::Accent; $lblMiniPct.ForeColor = [Theme]::Text }
        $barMini.Invalidate()
        if ($script:GameOn) { $lblMiniState.Text = "Modo Juego: $($script:GameName)" }
        elseif ($Config.GameMode) { $lblMiniState.Text = 'Modo Juego: en espera' }
        else { $lblMiniState.Text = 'Modo Juego: apagado' }
    } catch {}
}

$miniTimer = New-Object System.Windows.Forms.Timer
$miniTimer.Interval = 2000
$miniTimer.Add_Tick({ Update-Mini })

function Show-Mini {
    if ($script:Full) { Set-FullScreen $false }
    $mini.BackColor = [Theme]::Bg
    Update-Theme $mini
    $x = [int]$Config.MiniX
    $y = [int]$Config.MiniY
    $ok = $false
    foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) { if ($sc.WorkingArea.Contains($x, $y)) { $ok = $true } }
    if (-not $ok) {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = $wa.Right - 270
        $y = $wa.Bottom - 150
    }
    $mini.Location = New-Object System.Drawing.Point($x, $y)
    $form.Hide()
    Update-Mini
    $mini.Show()
    $miniTimer.Start()
}

function Hide-Mini([bool]$openMain) {
    try { $Config.MiniX = $mini.Location.X; $Config.MiniY = $mini.Location.Y; Save-Config } catch {}
    $miniTimer.Stop()
    $mini.Hide()
    if ($openMain) { Show-Window }
}

# Si se abre la ventana principal (bandeja, etc.), la mini se esconde
$form.Add_VisibleChanged({ if ($form.Visible -and $mini.Visible) { Hide-Mini $false } })
$form.Add_FormClosed({ try { $mini.Close() } catch {} })

$btnMiniClean.Add_Click({ Invoke-CleanRam; Update-Mini })
$btnMiniOpen.Add_Click({ Hide-Mini $true })
$btnMiniHide.Add_Click({ Hide-Mini $false })

$btnMiniMode = New-Btn 'mini' 'nav' 434 6 46 28 $topbar $fSmall
$btnMiniMode.Radius = 8
$btnMiniMode.Add_Click({ Show-Mini })
$tipMini = New-Object System.Windows.Forms.ToolTip
$tipMini.SetToolTip($btnMiniMode, 'Modo mini: ventanita pequena siempre visible')

# Menu de la bandeja
$miMiniTray = New-Object System.Windows.Forms.ToolStripMenuItem('Modo mini')
$menu.Items.Insert(6, $miMiniTray)
$miUpdTray = New-Object System.Windows.Forms.ToolStripMenuItem('Buscar actualizacion')
$menu.Items.Insert(7, $miUpdTray)
$miMiniTray.Add_Click({ Show-Mini })

# =====================================================================
#  MODO JUEGO / FOCO
# =====================================================================
function Get-GameApps {
    return @(([string]$Config.GameApps).Split(',') | ForEach-Object { ($_.Trim()) -replace '\.exe$', '' } | Where-Object { $_ -and ($_ -match '^[\w\.\- ]+$') })
}

function Find-GameTarget {
    foreach ($a in (Get-GameApps)) {
        $p = @(Get-Process -Name $a -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID }) | Select-Object -First 1
        if ($p) { return $p }
    }
    if ($Config.GameAuto) {
        $fpid = [RamApi3]::FullscreenPid()
        if ($fpid -gt 0 -and $fpid -ne $PID) {
            $p = Get-Process -Id $fpid -ErrorAction SilentlyContinue
            if ($p) {
                $k = ([string]$p.ProcessName).ToLowerInvariant()
                if ((-not (Test-ProtectedName $p.ProcessName)) -and ($script:GameExclude -notcontains $k)) { return $p }
            }
        }
    }
    return $null
}

# Presion segura: recorta lo de fondo SIN tocar el juego ni los procesos del sistema grafico/audio
function Apply-GamePressure([bool]$log = $false) {
    try {
        $skip = @('idle', 'system', 'registry', 'memory compression', 'secure system', 'vmmem', 'vmmemwsl') + @($script:TrimSkip)
        $n = 0
        foreach ($p in @(Get-Process)) {
            if ($p.Id -le 4 -or $p.Id -eq $PID) { continue }
            $nm = [string]$p.ProcessName
            if ($p.Id -eq $script:GamePid -or $nm -eq $script:GameName) { continue }
            if ($skip -contains $nm.ToLowerInvariant()) { continue }
            [void][RamApi]::MemPrio($p.Id, 1)
            if ($p.WorkingSet64 -gt 20MB) { if ([RamApi]::Trim($p.Id)) { $n++ } }
        }
        if ($IsAdmin) {
            if ([RamApi]::Priv('SeProfileSingleProcessPrivilege')) { [void][RamApi]::MemCmd(5) }
        }
        if ($log) { Write-Log "Modo Juego: $n procesos de fondo recortados" }
    } catch {}
}

function Update-GameUi {
    try {
        if ($script:GameOn) {
            $nm = [string]$script:GameName
            if ($nm.Length -gt 16) { $nm = $nm.Substring(0, 16) }
            $lblSideText.Text = "Juego: $nm"
        } else {
            if ($script:Enabled) {
                $names = @($script:Rows | ForEach-Object { Get-RowName $_ } | Where-Object { $_ })
                $lblSideText.Text = "Vigilando $($names.Count) app(s)"
            } else { $lblSideText.Text = 'Inactivo' }
        }
        Update-Mini
    } catch {}
}

function Start-GameMode($p) {
    if ($script:GameOn) { return }
    $script:GameOn = $true
    $script:GamePid = [int]$p.Id
    $script:GameName = [string]$p.ProcessName
    $script:GameT0 = Get-Date
    $script:GameTickN = 0
    $script:GameNotify = [bool]$Config.Notify
    $Config.Notify = $false      # sin globos mientras juegas (Save-Config guarda el valor real)
    Write-Log "MODO JUEGO activado: $($script:GameName)"

    foreach ($q in @(Get-Process -Name $script:GameName -ErrorAction SilentlyContinue)) {
        try { $q.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal } catch {}
        [void][RamApi]::MemPrio($q.Id, 5)
    }

    if ($Config.GameKill) {
        try { Scan-Background } catch {}
        $list = @($script:BgRows.Values | Where-Object {
            $_.Cat -eq 'Innecesario' -and $_.Cnt -gt 0 -and
            ($_.Name -ne $script:GameName) -and
            ($script:GameKeep -notcontains ([string]$_.Name).ToLowerInvariant())
        })
        $closed = 0
        foreach ($r in $list) {
            $k = Stop-ProcByName $r.Name
            if ($k -gt 0) { $closed++; $rec = Get-HistRec $r.Name; $rec.Kills = [int]$rec.Kills + $k }
        }
        if ($closed -gt 0) { Save-History; Write-Log "Modo Juego: cerrados $closed procesos innecesarios" }
    }

    Apply-GamePressure $true
    Update-GameUi
}

function Stop-GameMode {
    if (-not $script:GameOn) { return }
    $mins = [math]::Round(((Get-Date) - $script:GameT0).TotalMinutes, 0)
    $nm = [string]$script:GameName
    $script:GameOn = $false
    $script:GamePid = 0
    $Config.Notify = [bool]$script:GameNotify
    try { Reset-AllMemPrio } catch {}
    Write-Log "MODO JUEGO terminado: $nm ($mins min)"
    Update-GameUi
    if ($Config.Notify) {
        $tray.ShowBalloonTip(2500, 'RamLimiter', "Modo Juego terminado ($nm, $mins min)", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

function Invoke-GameTick {
    try {
        if (-not $Config.GameMode) { if ($script:GameOn) { Stop-GameMode }; return }
        if ($script:GameOn) {
            $alive = Get-Process -Id $script:GamePid -ErrorAction SilentlyContinue
            if ((-not $alive) -or ([string]$alive.ProcessName -ne $script:GameName)) { Stop-GameMode; return }
            $script:GameTickN++
            if (($script:GameTickN % 10) -eq 0) { Apply-GamePressure $false }
            return
        }
        if ($script:Cleaning) { return }
        $t = Find-GameTarget
        if ($t) { Start-GameMode $t }
    } catch {}
}

$gameTimer = New-Object System.Windows.Forms.Timer
$gameTimer.Interval = 3000
$gameTimer.Add_Tick({ Invoke-GameTick })
$gameTimer.Start()

$tgGame.Add_CheckedChanged({
    $Config.GameMode = $tgGame.Checked
    Save-Config
    if ((-not $tgGame.Checked) -and $script:GameOn) { Stop-GameMode }
    Update-Mini
})
$tgGameAuto.Add_CheckedChanged({ $Config.GameAuto = $tgGameAuto.Checked; Save-Config })
$tgGameKill.Add_CheckedChanged({ $Config.GameKill = $tgGameKill.Checked; Save-Config })
$txtGameApps.Add_Leave({ $Config.GameApps = $txtGameApps.Text.Trim(); Save-Config })

# =====================================================================
#  ACTUALIZACION AUTOMATICA
# =====================================================================
function Get-RemoteScript([string]$url) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Timeout = 8000
    $req.ReadWriteTimeout = 8000
    $req.UserAgent = 'RamLimiter-Updater'
    $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::BypassCache)
    $resp = $req.GetResponse()
    try {
        if ($resp.ResponseUri.Scheme -ne 'https') { throw 'El enlace redirige a una direccion no segura (http).' }
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $resp.Close() }
}

# Comprueba que el texto descargado sea de verdad RamLimiter, sin errores de sintaxis, y lee su version
function Test-RemoteScript([string]$text) {
    $res = [pscustomobject]@{ Ok = $false; Ver = ''; Msg = '' }
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 20000 -or $text -notmatch 'ProcessRamLimiterApp') {
        $res.Msg = 'El enlace no devuelve el script de RamLimiter.'
        return $res
    }
    $m = [regex]::Match($text, '\$AppVersion\s*=\s*''([0-9]+(?:\.[0-9]+){1,3})''')
    if (-not $m.Success) { $res.Msg = 'El script remoto no tiene numero de version.'; return $res }
    $tok = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        $e0 = $errs[0]
        $res.Msg = 'Errores de sintaxis (linea ' + $e0.Extent.StartLineNumber + '): ' + $e0.Message
        return $res
    }
    $res.Ok = $true
    $res.Ver = $m.Groups[1].Value
    return $res
}

function Set-UpdStatus([string]$t) { try { $lblUpdStatus.Text = $t } catch {} }

function Invoke-UpdateCheck([bool]$manual) {
    if ((-not $manual) -and $script:GameOn) { return }
    $url = ([string]$Config.UpdateUrl).Trim()
    if (-not $url) {
        if ($manual) { [void][System.Windows.Forms.MessageBox]::Show('Pega primero el enlace de actualizacion en Ajustes.', 'RamLimiter') }
        return
    }
    if ($url -notmatch '^https://') {
        Set-UpdStatus 'El enlace debe empezar con https://'
        if ($manual) { [void][System.Windows.Forms.MessageBox]::Show('El enlace debe empezar con https://', 'RamLimiter') }
        return
    }
    $oldCur = $form.Cursor
    if ($manual) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try {
        Set-UpdStatus 'Buscando actualizaciones...'
        $text = Get-RemoteScript $url
        $chk = Test-RemoteScript $text
        if (-not $chk.Ok) {
            Set-UpdStatus $chk.Msg
            Write-Log "Actualizacion: $($chk.Msg)"
            if ($manual) { [void][System.Windows.Forms.MessageBox]::Show($chk.Msg, 'RamLimiter') }
            return
        }
        if ([version]$chk.Ver -gt [version]$AppVersion) {
            $script:UpdVer = $chk.Ver
            $script:UpdText = $text
            Set-UpdStatus "Nueva version disponible: v$($chk.Ver)"
            $btnUpdInstall.Text = "Instalar v$($chk.Ver)"
            $btnUpdInstall.Visible = $true
            $miUpdTray.Text = "Instalar actualizacion v$($chk.Ver)"
            Write-Log "Actualizacion disponible: v$($chk.Ver) (instalada: v$AppVersion)"
            if ($manual) { Install-Update $false }
            elseif ($Config.UpdateSilent) { Install-Update $true }
            elseif ($Config.Notify) {
                $tray.ShowBalloonTip(4000, 'RamLimiter', "Hay una version nueva (v$($chk.Ver)). Clic derecho en el icono > Instalar actualizacion.", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } else {
            Set-UpdStatus "Ya tienes la ultima version (v$AppVersion)"
            if ($manual) { [void][System.Windows.Forms.MessageBox]::Show("Ya tienes la ultima version (v$AppVersion).", 'RamLimiter') }
        }
    } catch {
        Set-UpdStatus 'No se pudo comprobar (sin internet o enlace invalido)'
        Write-Log "Actualizacion: no se pudo comprobar ($($_.Exception.Message))"
        if ($manual) { [void][System.Windows.Forms.MessageBox]::Show("No se pudo comprobar:`n$($_.Exception.Message)", 'RamLimiter') }
    } finally {
        $form.Cursor = $oldCur
    }
}

function Install-Update([bool]$silent) {
    if (-not $script:UpdText) { return }
    if ($IsExe) {
        [void][System.Windows.Forms.MessageBox]::Show("Estas usando la version .exe: no se puede reemplazar sola.`nDescarga la version nueva (v$($script:UpdVer)) a mano.", 'RamLimiter')
        return
    }
    if ((-not $ScriptPath) -or (-not (Test-Path $ScriptPath))) {
        [void][System.Windows.Forms.MessageBox]::Show('No se encontro el archivo del script para reemplazarlo.', 'RamLimiter')
        return
    }
    if (-not $silent) {
        $msg = "Hay una version nueva (v$($script:UpdVer)). Tu version: v$($AppVersion).`n`nSe guardara una copia de la actual (.bak) y RamLimiter se reiniciara.`n`nInstalar ahora?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'RamLimiter - actualizacion', 'YesNo', 'Question')
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $chk = Test-RemoteScript $script:UpdText
    if (-not $chk.Ok) { Set-UpdStatus $chk.Msg; Write-Log "Actualizacion cancelada: $($chk.Msg)"; return }
    try {
        Save-Config
        Save-History
        Copy-Item -Path $ScriptPath -Destination ($ScriptPath + '.bak') -Force
        $tmp = $ScriptPath + '.new'
        [System.IO.File]::WriteAllText($tmp, $script:UpdText, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -Path $tmp -Destination $ScriptPath -Force
        Write-Log "ACTUALIZADO a v$($chk.Ver). Copia anterior: $($ScriptPath).bak"
        $psExe = (Get-Process -Id $PID).Path
        $inner = '"{0}" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Child' -f $psExe, $ScriptPath
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c timeout /t 3 /nobreak >nul & start "" ' + $inner) -WindowStyle Hidden
        Exit-App
    } catch {
        Write-Log "No se pudo instalar la actualizacion: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show("No se pudo instalar la actualizacion:`n$($_.Exception.Message)", 'RamLimiter')
    }
}

$tgUpd.Add_CheckedChanged({ $Config.UpdateAuto = $tgUpd.Checked; Save-Config })
$tgUpdSilent.Add_CheckedChanged({ $Config.UpdateSilent = $tgUpdSilent.Checked; Save-Config })
$txtUpdUrl.Add_Leave({ $Config.UpdateUrl = $txtUpdUrl.Text.Trim(); Save-Config })
$btnUpdCheck.Add_Click({ $Config.UpdateUrl = $txtUpdUrl.Text.Trim(); Save-Config; Invoke-UpdateCheck $true })
$btnUpdInstall.Add_Click({ Install-Update $false })
$miUpdTray.Add_Click({ if ($script:UpdVer) { Install-Update $false } else { Show-Window; Invoke-UpdateCheck $true } })

# Primera comprobacion 20 s despues de abrir; luego cada 6 horas
$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 20000
$updTimer.Add_Tick({
    $updTimer.Interval = 21600000
    if ($Config.UpdateAuto) { Invoke-UpdateCheck $false }
})
$updTimer.Start()

# =====================================================================
#  FIN DEL BLOQUE v2.1
# =====================================================================

# =====================================================================
#  PANTALLA "PERSONALIZA TU PERFIL" (se muestra ANTES de la animacion de inicio)
# =====================================================================
Add-CfgDefault 'ProfileSetup' $true

[void](New-Panel 20 500 532 1 $cardC 'border')
$tgProfSetup = New-RowOn $cardC 500 'Pantalla de perfil al iniciar' 'Solo si aun no tienes nombre ni foto, antes de la carga.'
$cardC.Height = 572
$tgProfSetup.Checked = [bool]$Config.ProfileSetup
$tgProfSetup.Add_CheckedChanged({ $Config.ProfileSetup = $tgProfSetup.Checked; Save-Config })

$script:SuForm = $null
$script:SuAv   = $null
$script:SuTxt  = $null

function Complete-ProfileSetup {
    try {
        $nm = $script:SuTxt.Text.Trim()
        if ($txtName.Text -ne $nm) { $txtName.Text = $nm }
    } catch {}
    $script:SuForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

function Select-SetupPhoto {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Imagenes|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
    $dlg.Title = 'Elige tu foto de perfil'
    try {
        if ($dlg.ShowDialog($script:SuForm) -eq [System.Windows.Forms.DialogResult]::OK) {
            Save-AvatarFrom $dlg.FileName
            $script:SuAv.Photo = $null
            Set-AvatarPhoto (Read-Avatar)
            $script:SuAv.Photo = $script:AvatarBmp
            $script:SuAv.Invalidate()
            Write-Log 'Foto de perfil actualizada'
        }
    } catch { Write-Log "No se pudo cargar la foto: $($_.Exception.Message)" }
    $dlg.Dispose()
}

function Show-ProfileSetup {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ClientSize = New-Object System.Drawing.Size(460, 470)
    $f.StartPosition = 'CenterScreen'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.KeyPreview = $true
    $f.BackColor = [Theme]::Bg
    $f.Font = $fBody
    $script:SuForm = $f
    $f.Add_HandleCreated({ try { [RamApi]::Round($script:SuForm.Handle) } catch {} })
    $f.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen([Theme]::Border)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
        $pen.Dispose()
    })
    $f.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Complete-ProfileSetup }
    })
    $f.Add_Shown({ try { $script:SuTxt.Focus() } catch {} })

    $l1 = New-Lbl 'BIENVENIDO' 0 22 $f 'muted' $fCaps 460
    $l1.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $l2 = New-Lbl 'Personaliza tu perfil' 0 40 $f 'text' $fTitle 460
    $l2.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $l3 = New-Lbl 'Elige tu foto y tu nombre. Podras cambiarlos luego en Perfil.' 20 86 $f 'muted' $fBody 420
    $l3.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    # nombre actual (si sigue el de fabrica, el campo empieza vacio)
    $cur = [string]$txtName.Text
    if ($cur -ieq 'RAMLIMITER') { $cur = '' }
    $ini = 'R'
    if ($cur.Trim()) { $ini = $cur.Trim().Substring(0, 1).ToUpper() }

    $av = New-Object LcAvatar
    $av.Location = New-Object System.Drawing.Point(166, 120)
    $av.Size = New-Object System.Drawing.Size(128, 128)
    $av.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 44)
    $av.Initial = $ini
    $av.Photo = $script:AvatarBmp
    $f.Controls.Add($av)
    $script:SuAv = $av

    $bUp = New-Btn 'Subir foto' 'accent' 100 264 130 36 $f $fBody
    $bDel = New-Btn 'Quitar foto' 'ghost' 240 264 120 36 $f $fBody

    [void](New-Lbl 'NOMBRE' 60 320 $f 'muted' $fCaps)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(60, 340)
    $t.Size = New-Object System.Drawing.Size(340, 26)
    $t.BorderStyle = 'FixedSingle'
    $t.Font = $fBody
    $t.Tag = 'input'
    $t.MaxLength = 24
    $t.Text = $cur
    $f.Controls.Add($t)
    $script:SuTxt = $t
    $t.Add_HandleCreated({ [void][RamApi]::SendMsgStr($script:SuTxt.Handle, 0x1501, 1, 'Como quieres que te llame?') })
    $t.Add_TextChanged({
        $n = $script:SuTxt.Text.Trim()
        $i = 'R'
        if ($n) { $i = $n.Substring(0, 1).ToUpper() }
        $script:SuAv.Initial = $i
        $script:SuAv.Invalidate()
    })

    $bGo = New-Btn 'Continuar' 'accent' 60 400 340 46 $f $fBtn
    $bGo.Radius = 12

    $av.Add_Click({ Select-SetupPhoto })
    $bUp.Add_Click({ Select-SetupPhoto })
    $bDel.Add_Click({
        Remove-Item $AvatarPath -Force -ErrorAction SilentlyContinue
        $script:SuAv.Photo = $null
        Set-AvatarPhoto $null
        $script:SuAv.Invalidate()
    })
    $bGo.Add_Click({ Complete-ProfileSetup })

    # arrastrar la ventana desde el fondo o los titulos
    $setupDrag = { param($s, $e) if ($e.Button -eq 'Left') { [RamApi]::Drag($script:SuForm.Handle) } }
    foreach ($c in @($f, $l1, $l2, $l3)) { $c.Add_MouseDown($setupDrag) }

    Update-Theme $f
    [void]$f.ShowDialog()
    $f.Dispose()
    $script:SuForm = $null
    $script:SuAv = $null
    $script:SuTxt = $null
}

# ---------- PANTALLA COMPLETA (boton del titulo, F11 para entrar/salir, Esc para salir) ----------
$btnFull = New-Btn '[ ]' 'nav' 486 6 36 28 $topbar $fSmall
$btnFull.Radius = 8
$script:TipFull = New-Object System.Windows.Forms.ToolTip
$script:TipFull.SetToolTip($btnFull, 'Pantalla completa (F11)')

$script:Full = $false
$script:FsNormal = $null
$script:FsPt = New-Object System.Drawing.Point(0, 0)
$script:FsOrig = @{}
foreach ($c in @($topbar.Controls) + @($sidebar.Controls)) { $script:FsOrig[$c] = $c.Location }
foreach ($k in @($pages.Keys)) { foreach ($c in $pages[$k].Controls) { $script:FsOrig[$c] = $c.Location } }

function Apply-FsLayout {
    $cw = $form.ClientSize.Width
    $ch = $form.ClientSize.Height
    $dx = [math]::Max(0, $cw - 840)
    $dy = [math]::Max(0, $ch - 540)
    $sidebar.Height = $ch
    $topbar.Width = $cw - 220
    foreach ($c in @($topbar.Controls)) {
        $o = $script:FsOrig[$c]
        if ($o) { $c.Left = $o.X + $dx }
    }
    foreach ($c in @($sidebar.Controls)) {
        $o = $script:FsOrig[$c]
        if ($o -and $o.Y -ge 400) { $c.Top = $o.Y + $dy }
    }
    foreach ($k in @($pages.Keys)) {
        $pg = $pages[$k]
        $pg.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
        $pg.SetBounds(220, 40, ($cw - 220), ($ch - 40))
        $offX = [int]($dx / 2)
        $offY = 0
        if (-not $pg.AutoScroll) { $offY = [int]($dy / 2) }
        foreach ($c in @($pg.Controls)) {
            $o = $script:FsOrig[$c]
            if ($o) { $c.Location = New-Object System.Drawing.Point(($o.X + $offX), ($o.Y + $offY)) }
        }
    }
}

function Set-FullScreen([bool]$on) {
    if ($on -eq $script:Full) { return }
    if ($on) {
        $script:FsNormal = $form.Bounds
        $form.WindowState = 'Normal'
        $scr = [System.Windows.Forms.Screen]::FromControl($form)
        $script:FsPt = $scr.Bounds.Location
        $script:Full = $true
        $form.Bounds = $scr.Bounds
        try { [RamApi2]::Corners($form.Handle, 1) } catch {}
        $btnFull.Text = '[=]'
        Write-Log 'Pantalla completa: ACTIVADA (F11 o Esc para salir)'
    } else {
        $script:Full = $false
        if ($script:FsNormal) { $form.Bounds = $script:FsNormal }
        try { [RamApi2]::Corners($form.Handle, 2) } catch {}
        $btnFull.Text = '[ ]'
        Write-Log 'Pantalla completa: DESACTIVADA'
    }
    Apply-FsLayout
    $form.Invalidate($true)
}

$btnFull.Add_Click({ Set-FullScreen (-not $script:Full) })
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'F11') { $e.SuppressKeyPress = $true; Set-FullScreen (-not $script:Full) }
    elseif ($e.KeyCode -eq 'Escape' -and $script:Full) { $e.SuppressKeyPress = $true; Set-FullScreen $false }
})
# En pantalla completa la ventana no se puede arrastrar
$form.Add_LocationChanged({
    if ($script:Full -and ($form.Location -ne $script:FsPt)) { $form.Location = $script:FsPt }
})

# =====================================================================
#  FIN DEL BLOQUE
# =====================================================================

# ---------- Arranque ----------
Load-History
Update-ProcessList
Load-Profile ([string]$Config.ActiveProfile)
Update-ProfileCombos

$userName = [string]$Config.UserName
if ([string]::IsNullOrWhiteSpace($userName)) { $userName = 'RAMLIMITER' }
$txtName.Text = $userName
Set-AvatarPhoto (Read-Avatar)
Sync-Profile
$txtName.Add_TextChanged({ Sync-Profile; $Config.UserName = $txtName.Text.Trim(); Save-Config })

$nudInterval.Value = [decimal][math]::Min([math]::Max([int]$Config.IntervalSec, 1), 3600)
$tgKill.Checked    = [bool]$Config.KillHeaviest
$tgAuto.Checked    = [bool]$Config.Autostart
$tgNotify.Checked  = [bool]$Config.Notify
$tgBlock.Checked   = [bool]$Config.BlockEnabled
$tgSplash.Checked  = [bool]$Config.Splash
$tgAutoClean.Checked = [bool]$Config.AutoClean
$tgHardCap.Checked = [bool]$Config.HardCap
$nudThresh.Value   = [decimal][math]::Min([math]::Max([int]$Config.CleanThreshold, 50), 98)
$timer.Interval    = [int]$nudInterval.Value * 1000

$tgKill.Add_CheckedChanged({ $Config.KillHeaviest = $tgKill.Checked; Save-Config })
$tgNotify.Add_CheckedChanged({ $Config.Notify = $tgNotify.Checked; Save-Config })
$tgAuto.Add_CheckedChanged({ $Config.Autostart = $tgAuto.Checked; Set-Autostart $tgAuto.Checked; Save-Config })
$tgBlock.Add_CheckedChanged({
    $Config.BlockEnabled = $tgBlock.Checked
    Save-Config
    if ($tgBlock.Checked) { Write-Log 'Vigilancia de procesos bloqueados: ACTIVADA' } else { Write-Log 'Vigilancia de procesos bloqueados: PAUSADA' }
})
$tgSplash.Add_CheckedChanged({ $Config.Splash = $tgSplash.Checked; Save-Config })
$tgAutoClean.Add_CheckedChanged({ $Config.AutoClean = $tgAutoClean.Checked; Save-Config })
$nudThresh.Add_ValueChanged({ $Config.CleanThreshold = [int]$nudThresh.Value; Save-Config })
$tgHardCap.Add_CheckedChanged({
    $Config.HardCap = $tgHardCap.Checked
    Save-Config
    if (-not $tgHardCap.Checked) { foreach ($r in $script:Rows) { if ($r.Capped) { Release-Cap $r } } }
})
$btnElevate.Add_Click({
    try {
        $psExe = (Get-Process -Id $PID).Path
        if ($IsExe) { $inner = '"{0}"' -f $psExe }
        else { $inner = '"{0}" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Child' -f $psExe, $ScriptPath }
        $argl = '/c timeout /t 3 /nobreak >nul & start "" ' + $inner
        Start-Process -FilePath 'cmd.exe' -ArgumentList $argl -Verb RunAs -WindowStyle Hidden
        Exit-App
    } catch { Write-Log "No se pudo reiniciar como administrador: $($_.Exception.Message)" }
})

Set-TrayState 'off'
Apply-FontScale $form
Set-AppTheme
Show-Page 'Inicio'
Sync-Home
$wasEnabled = [bool]$Config.Enabled
Set-Enabled $false
if ($wasEnabled) { Set-Enabled $true }
Invoke-Check

# Primer analisis de procesos (para mostrar datos reales en la animacion de inicio)
try { Scan-Background } catch {}

# Animacion de inicio: la ventana principal espera invisible hasta que termine
$script:UseSplash = ((-not $Minimized) -and [bool]$Config.Splash)
$script:UseProfileSetup = ((-not $Minimized) -and [bool]$Config.ProfileSetup)
if ($script:UseProfileSetup) {
    # solo usuarios nuevos: sin nombre propio y sin foto
    $nmCheck = ([string]$Config.UserName).Trim()
    $hasName = [bool]($nmCheck -and ($nmCheck -ine 'RAMLIMITER'))
    $hasPhoto = [bool](Test-Path $AvatarPath)
    if ($hasName -or $hasPhoto) { $script:UseProfileSetup = $false }
}
if ($script:UseSplash -or $script:UseProfileSetup) {
    $form.Opacity = 0
    $form.Enabled = $false
}

$timer.Start()
$bgTimer.Start()
$blockTimer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    $timer.Stop()
    $bgTimer.Stop()
    $blockTimer.Stop()
    foreach ($r in $script:Rows) { Restore-Priority $r }
    Save-History
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
