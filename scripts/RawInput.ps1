# RawInput.ps1
# 只监听 G304 (VID_046D&PID_C53F) 自己的 HID 输入报告。
# 触控板 / 虚拟鼠标 (TENCENTMYAPPSHIDBUS、GVINPUT、HTIX5288) 会被排除，
# 所以"触控板能动但 G304 不动"这种场景能被客观区分开。
#
# 注意：RegisterRawInputDevices 在本机上用 (RIDEV_INPUTSINK + NULL hwndTarget) 会返回
#       ERROR_INVALID_PARAMETER(87)，必须先建一个真实窗口（message-only）再注册。

if (-not ('MouseWatch' -as [type])) {
    $code = @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;

public static class MouseWatch
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RAWINPUTDEVICE { public ushort usUsagePage; public ushort usUsage; public uint dwFlags; public IntPtr hwndTarget; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterRawInputDevices(IntPtr p, uint n, uint size);
    [DllImport("user32.dll")]
    static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")]
    static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdrSize);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern uint GetRawInputDeviceInfo(IntPtr hDevice, uint uiCommand, IntPtr pInfo, ref uint pcbSize);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowEx(uint exStyle, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string name);

    const uint RIDEV_INPUTSINK = 0x00000100;
    const uint RID_INPUT       = 0x10000003;
    const uint RIDI_DEVICEPATH  = 0x80000014;
    const uint WM_INPUT        = 0x00FF;
    const uint PM_REMOVE       = 0x0001;
    const int  HDR             = 24;   // sizeof(RAWINPUTHEADER) on x64
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);

    static IntPtr s_buf = IntPtr.Zero;
    static IntPtr s_hwnd = IntPtr.Zero;
    static int s_mode = 0;   // 1 = NULL+flags0, 2 = message-only window + INPUTSINK

    static bool TryRegister(IntPtr hwnd, uint flags)
    {
        IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        try
        {
            var rid = new RAWINPUTDEVICE();
            rid.usUsagePage = 0x01;   // HID
            rid.usUsage     = 0x02;   // Mouse
            rid.dwFlags     = flags;
            rid.hwndTarget  = hwnd;
            Marshal.StructureToPtr(rid, p, false);
            return RegisterRawInputDevices(p, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        }
        finally { Marshal.FreeHGlobal(p); }
    }

    static bool Register()
    {
        if (s_buf == IntPtr.Zero) s_buf = Marshal.AllocHGlobal(8192);

        // 策略 1：hwndTarget = NULL, flags = 0（前台接收）
        if (TryRegister(IntPtr.Zero, 0)) { s_mode = 1; return true; }

        // 策略 2：建一个 message-only 窗口，用 RIDEV_INPUTSINK 后台接收
        s_hwnd = CreateWindowEx(0, "STATIC", "MouseWatchSink", 0, 0, 0, 0, 0,
                                HWND_MESSAGE, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        if (s_hwnd != IntPtr.Zero)
        {
            if (TryRegister(s_hwnd, RIDEV_INPUTSINK)) { s_mode = 2; return true; }
        }
        return false;
    }

    static string DevicePath(IntPtr hDev)
    {
        uint need = 0;
        GetRawInputDeviceInfo(hDev, RIDI_DEVICEPATH, IntPtr.Zero, ref need);
        if (need == 0) return null;
        IntPtr b = Marshal.AllocHGlobal((int)need);
        try
        {
            uint sz = need;
            if (GetRawInputDeviceInfo(hDev, RIDI_DEVICEPATH, b, ref sz) == 0) return null;
            return Marshal.PtrToStringUni(b);
        }
        finally { Marshal.FreeHGlobal(b); }
    }

    static int Pump(int count, string filter)
    {
        int other = 0;
        return Pump(count, filter, false, ref other);
    }

    static int Pump(int count, string filter, bool split, ref int other)
    {
        MSG m;
        uint sz;
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, PM_REMOVE))
        {
            if (m.message == WM_INPUT)
            {
                sz = 8192;
                if (GetRawInputData(m.lParam, RID_INPUT, s_buf, ref sz, HDR) > 0)
                {
                    uint type = (uint)Marshal.ReadInt32(s_buf, 0);
                    if (type == 0) // RIM_MOUSE
                    {
                        int dx = Marshal.ReadInt32(s_buf, 32);
                        int dy = Marshal.ReadInt32(s_buf, 36);
                        if (dx != 0 || dy != 0)
                        {
                            IntPtr hDev = Marshal.ReadIntPtr(s_buf, 8);
                            string path = DevicePath(hDev);
                            bool isTarget = path != null && path.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
                            if (isTarget) count++;
                            else if (split) other++;
                        }
                    }
                }
            }
            TranslateMessage(ref m);
            DispatchMessage(ref m);
        }
        return count;
    }

    public static int Mode { get { return s_mode; } }

    // 静默监听 ms 毫秒，返回 G304 移动事件数；注册失败返回 -1
    public static int Watch(int ms, string filter)
    {
        if (!Register()) return -1;
        var sw = Stopwatch.StartNew();
        int count = 0;
        while (sw.ElapsedMilliseconds < ms)
        {
            count = Pump(count, filter);
            Thread.Sleep(4);
        }
        return count;
    }

    // 同时统计 G304 与"其它鼠标"的移动事件数。
    // 返回 int[2] = { G304 事件数, 其它鼠标事件数 }；注册失败返回 null。
    // 用途：G304==0 且 其它>0 => G304 死了但触控板是活的 => 唯一可信的"死鼠标"判据。
    public static int[] WatchBoth(int ms, string filter)
    {
        if (!Register()) return null;
        var sw = Stopwatch.StartNew();
        int g = 0, o = 0;
        while (sw.ElapsedMilliseconds < ms)
        {
            g = Pump(g, filter, true, ref o);
            Thread.Sleep(4);
        }
        return new int[] { g, o };
    }
}
'@
    try {
        Add-Type -TypeDefinition $code -ErrorAction Stop
    } catch {
        Write-Warning "MouseWatch 编译失败: $($_.Exception.Message)"
    }
}

function Measure-G304 {
    <#
      .SYNOPSIS
        监听指定毫秒数，统计 G304 自己的鼠标移动事件数。
      .OUTPUTS
        [pscustomobject] @{ Count = <int>; Ok = <bool>; Device = <string> }
    #>
    param(
        [int] $Milliseconds = 8000,
        [string] $Filter = 'VID_046D&PID_C53F',
        [switch] $Quiet
    )
    if (-not ('MouseWatch' -as [type])) {
        return [pscustomobject]@{ Count = -1; Ok = $false; Device = 'n/a' }
    }
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  >>> 请用 G304 鼠标晃动一下（触控板不算），监听 $Milliseconds 毫秒…" -ForegroundColor Cyan
    }
    $n = [MouseWatch]::Watch($Milliseconds, $Filter)
    if (-not $Quiet) {
        if ($n -lt 0) { Write-Host "  >>> raw input 注册失败，无法自动判定" -ForegroundColor Yellow }
        else { Write-Host "  >>> 收到 G304 移动事件: $n" -ForegroundColor $(if ($n -gt 0) { 'Green' } else { 'Red' }) }
    }
    [pscustomobject]@{
        Count  = $n
        Ok     = ($n -gt 0)
        Device = $Filter
    }
}
