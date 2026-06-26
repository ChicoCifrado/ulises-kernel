const std = @import("std");
const builtin = @import("builtin");
const pci = @import("pci.zig");
const global_alloc = @import("../mem/global.zig");
const x86_64 = @import("../arch/x86_64.zig");

const virtToPhys = x86_64.virtToPhys;

const UHCI_FRAMELIST_SIZE = 1024;
const UHCI_TD_ALIGN = 16;
const UHCI_QH_ALIGN = 16;
const MAX_PACKET_SIZE = 64;
const MAX_DEVICES = 16;

const UHCI_CMD = 0x00;
const UHCI_STS = 0x02;
const UHCI_INTR = 0x04;
const UHCI_FRNUM = 0x06;
const UHCI_FLBASE = 0x08;
const UHCI_SOF = 0x0C;
const UHCI_PORTSC1 = 0x10;
const UHCI_PORTSC2 = 0x12;

const UHCI_CMD_GRESET = 1 << 0;
const UHCI_CMD_HCRESET = 1 << 1;
const UHCI_CMD_RS = 1 << 2;
const UHCI_CMD_RD = 1 << 3;
const UHCI_CMD_CF = 1 << 6;
const UHCI_CMD_MAXP = 1 << 7;

const UHCI_STS_HCHALTED = 1 << 5;
const UHCI_STS_USBINT = 1 << 0;
const UHCI_STS_ERRINT = 1 << 1;
const UHCI_STS_RD = 1 << 3;
const UHCI_STS_RI = 1 << 5;

const PORTSC_CONNECT = 1 << 0;
const PORTSC_ENABLE = 1 << 2;
const PORTSC_RESET = 1 << 9;
const PORTSC_LOWSPEED = 1 << 8;

const USB_DEVREQ_GET_DESCRIPTOR = 0x06;
const USB_DEVREQ_SET_ADDRESS = 0x05;
const USB_DEVREQ_SET_CONFIG = 0x09;
const USB_DEVREQ_SET_PROTOCOL = 0x0B;
const USB_DEVREQ_SET_IDLE = 0x0A;

const USB_DT_DEVICE = 1;
const USB_DT_CONFIG = 2;

const USB_CLASS_HID = 3;
const USB_SUBCLASS_BOOT = 1;
const USB_PROTOCOL_KEYBOARD = 1;

const TD_TOKEN_ACTIVE = 1 << 23;
const TD_TOKEN_STALLED = 1 << 25;
const TD_TOKEN_BABBLE = 1 << 26;
const TD_TOKEN_NAK = 1 << 27;
const TD_TOKEN_ERR = 1 << 28;
const TD_TOKEN_IOC = 1 << 24;
const TD_TOKEN_SETUP = 0x00 << 19;
const TD_TOKEN_IN = 0x01 << 19;
const TD_TOKEN_OUT = 0x02 << 19;
const TD_TOGGLE_DATA0 = 0x00 << 29;
const TD_TOGGLE_DATA1 = 0x01 << 29;

const PID_SETUP = 0x2D;
const PID_IN = 0x69;
const PID_OUT = 0xE1;

const RequestRecipientDevice = 0x00;
const RequestRecipientInterface = 0x01;
const RequestTypeStandard = 0x00;
const RequestTypeClass = 0x01;

const UsbSetupPacket = packed struct(u64) {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};

const Td = extern struct {
    link: u32,
    token: u32,
    buffer: u32,
    _rsvd: u32 = 0,
    buffer_hi: u32 = 0,
    _rsvd2: u32 = 0,
    _rsvd3: u32 = 0,
};

const Qh = extern struct {
    head_link: u32,
    element_link: u32,
};

const UsbDeviceDesc = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bcdUSB: u16,
    bDeviceClass: u8,
    bDeviceSubClass: u8,
    bDeviceProtocol: u8,
    bMaxPacketSize0: u8,
    idVendor: u16,
    idProduct: u16,
    bcdDevice: u16,
    iManufacturer: u8,
    iProduct: u8,
    iSerialNumber: u8,
    bNumConfigurations: u8,
};

const UsbEndpointDesc = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bEndpointAddress: u8,
    bmAttributes: u8,
    wMaxPacketSize: u16,
    bInterval: u8,
};

const UsbInterfaceDesc = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    bInterfaceNumber: u8,
    bAlternateSetting: u8,
    bNumEndpoints: u8,
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    iInterface: u8,
};

var kb_state: struct {
    modifiers: u8 = 0,
    keys: [6]u8 = [_]u8{0} ** 6,
    prev_modifiers: u8 = 0,
    prev_keys: [6]u8 = [_]u8{0} ** 6,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    caps: bool = false,
    last_key: u8 = 0,
    initialized: bool = false,
} = .{};

fn inb(port: u16) u8 {
    var val: u8 = undefined;
    asm volatile ("inb %[port], %[val]"
        : [val] "={al}" (val),
        : [port] "N{dx}" (port),
    );
    return val;
}

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

fn inw(port: u16) u16 {
    var val: u16 = undefined;
    asm volatile ("inw %[port], %[val]"
        : [val] "={ax}" (val),
        : [port] "N{dx}" (port),
    );
    return val;
}

fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "N{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    var val: u32 = undefined;
    asm volatile ("inl %[port], %[val]"
        : [val] "={eax}" (val),
        : [port] "N{dx}" (port),
    );
    return val;
}

fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
    );
}

fn delayMs(ms: u32) void {
    var i: u32 = 0;
    while (i < ms * 50000) {
        asm volatile ("pause");
        i += 1;
    }
}

var uhci_io_base: u16 = 0;
var framelist: [UHCI_FRAMELIST_SIZE]u32 align(4096) = [_]u32{0} ** UHCI_FRAMELIST_SIZE;
var td_buf: [2048]u8 align(16) = [_]u8{0} ** 2048;
var qh_buf: [512]u8 align(16) = [_]u8{0} ** 512;
var td_pool_idx: usize = 0;
var qh_pool_idx: usize = 0;

fn allocTd() *Td {
    const off = td_pool_idx * 32;
    td_pool_idx += 1;
    if (off + 32 > td_buf.len) @panic("TD pool exhausted");
    const addr = @intFromPtr(&td_buf) + off;
    @memset(td_buf[off..][0..32], 0);
    return @as(*Td, @ptrFromInt(addr));
}

fn allocQh() *Qh {
    const off = qh_pool_idx * 16;
    qh_pool_idx += 1;
    if (off + 16 > qh_buf.len) @panic("QH pool exhausted");
    const addr = @intFromPtr(&qh_buf) + off;
    @memset(qh_buf[off..][0..16], 0);
    return @as(*Qh, @ptrFromInt(addr));
}

fn uhciReadReg(reg: u16) u16 {
    return inw(uhci_io_base + reg);
}

fn uhciWriteReg(reg: u16, val: u16) void {
    outw(uhci_io_base + reg, val);
}

fn uhciWriteReg32(reg: u16, val: u32) void {
    outl(uhci_io_base + reg, val);
}

fn uhciPciInit() bool {
    if (builtin.target.cpu.arch != .x86_64) return false;

    const alloc = global_alloc.get();
    const devs = pci.enumerate(alloc) catch return false;
    defer alloc.free(devs);

    for (devs) |d| {
        if (d.class_code == 0x0C and d.subclass == 0x03 and d.prog_if == 0x00) {
            uhci_io_base = @as(u16, @truncate(d.bar0 & 0xFFF0));
            return uhci_io_base != 0;
        }
    }
    return false;
}

fn uhciReset() void {
    uhciWriteReg(UHCI_CMD, UHCI_CMD_HCRESET);
    delayMs(10);
    while (uhciReadReg(UHCI_CMD) & UHCI_CMD_HCRESET != 0) {
        delayMs(1);
    }

    uhciWriteReg(UHCI_CMD, UHCI_CMD_GRESET);
    delayMs(50);
    uhciWriteReg(UHCI_CMD, 0);
    delayMs(5);

    uhciWriteReg(UHCI_SOF, 0x40);

    uhciWriteReg32(UHCI_FLBASE, virtToPhys(&framelist));

    uhciWriteReg(UHCI_FRNUM, 0);

    uhciWriteReg(UHCI_STS, 0x003F);
    uhciWriteReg(UHCI_INTR, 0);

    var i: usize = 0;
    while (i < UHCI_FRAMELIST_SIZE) {
        framelist[i] = 0x0001; // Terminate (QH pointer with T=1)
        i += 1;
    }

    uhciWriteReg(UHCI_CMD, UHCI_CMD_RS | UHCI_CMD_MAXP | UHCI_CMD_CF);
    delayMs(5);
}

fn uhciPortDetect() ?u8 {
    var port: u8 = 0;
    while (port < 2) {
        const psc = uhciReadReg(UHCI_PORTSC1 + port * 2);
        if (psc & PORTSC_CONNECT != 0) {
            return port;
        }
        port += 1;
    }
    return null;
}

fn uhciPortReset(port: u8) void {
    uhciWriteReg(UHCI_PORTSC1 + port * 2, PORTSC_RESET);
    delayMs(50);
    uhciWriteReg(UHCI_PORTSC1 + port * 2, 0);
    delayMs(10);
}

fn uhciPortEnable(port: u8) void {
    const psc = uhciReadReg(UHCI_PORTSC1 + port * 2);
    uhciWriteReg(UHCI_PORTSC1 + port * 2, psc | PORTSC_ENABLE);
    delayMs(5);
}

fn isLowSpeed(port: u8) bool {
    return uhciReadReg(UHCI_PORTSC1 + port * 2) & PORTSC_LOWSPEED != 0;
}

fn uhciAsyncSubmit(td: *Td, qh: *Qh) void {
    qh.head_link = virtToPhys(td) | 0x0002 | 0x0004;
    qh.element_link = virtToPhys(td) | 0x0002;
    framelist[0] = virtToPhys(qh) | 0x0002;
    delayMs(5);
}

fn setupTdToken(bpid: u8, dev_addr: u8, endp: u8, toggle: u32, max_len: u32) u32 {
    const bpid_field: u32 = switch (bpid) {
        PID_SETUP => @as(u32, TD_TOKEN_SETUP),
        PID_IN => @as(u32, TD_TOKEN_IN),
        PID_OUT => @as(u32, TD_TOKEN_OUT),
        else => 0,
    };
    return TD_TOKEN_ACTIVE | toggle |
        (@as(u32, dev_addr) << 8) |
        (@as(u32, endp) << 15) |
        bpid_field |
        (max_len & 0x7FF);
}

fn buildTdChain(setup_pkt: *const UsbSetupPacket, data_buf: ?[]u8, direction: u8, dev_addr: u8, endp: u8) struct { td_setup: *Td, td_data: ?*Td, td_status: *Td } {
    const setup = allocTd();
    @memset(@as(*[32]u8, @ptrCast(setup)), 0);
    @memcpy(@as(*[8]u8, @ptrCast(&setup.buffer)), @as(*const [8]u8, @ptrCast(setup_pkt)));
    setup.link = 0x0001;
    setup.token = setupTdToken(PID_SETUP, dev_addr, endp, TD_TOGGLE_DATA0, 8);

    var prev = setup;
    var data_td: ?*Td = null;

    if (data_buf) |buf| {
        const data = allocTd();
        @memset(@as(*[32]u8, @ptrCast(data)), 0);
        data.link = 0x0001;
        data.buffer = virtToPhys(buf.ptr);

        if (direction == PID_IN) {
            data.token = setupTdToken(PID_IN, dev_addr, endp, TD_TOGGLE_DATA1, @as(u32, @intCast(buf.len)));
        } else {
            data.token = setupTdToken(PID_OUT, dev_addr, endp, TD_TOGGLE_DATA1, @as(u32, @intCast(buf.len)));
        }

        prev.link = virtToPhys(data);
        prev = data;
        data_td = data;
    }

    const status = allocTd();
    @memset(@as(*[32]u8, @ptrCast(status)), 0);
    status.link = 0x0001;
    if (direction == PID_IN or data_buf == null) {
        status.token = setupTdToken(PID_OUT, dev_addr, endp, TD_TOGGLE_DATA1, 0);
    } else {
        status.token = setupTdToken(PID_IN, dev_addr, endp, TD_TOGGLE_DATA1, 0);
    }
    status.token |= TD_TOKEN_IOC;

    prev.link = virtToPhys(status);

    return .{ .td_setup = setup, .td_data = data_td, .td_status = status };
}

fn waitTdComplete(td: *Td) bool {
    var tries: u32 = 0;
    while (tries < 50000) {
        if (td.token & TD_TOKEN_ACTIVE == 0) {
            return td.token & (TD_TOKEN_STALLED | TD_TOKEN_BABBLE | TD_TOKEN_ERR) == 0;
        }
        asm volatile ("pause");
        tries += 1;
    }
    return false;
}

fn controlTransfer(dev_addr: u8, setup: *const UsbSetupPacket, data: ?[]u8, direction: u8) bool {
    td_pool_idx = 0;
    qh_pool_idx = 0;

    const chain = buildTdChain(setup, data, direction, dev_addr, 0);

    const qh = allocQh();
    qh.head_link = virtToPhys(chain.td_setup) | 0x0002 | 0x0004;
    qh.element_link = virtToPhys(chain.td_setup) | 0x0002;

    framelist[0] = virtToPhys(qh) | 0x0002;
    delayMs(5);

    const ok = waitTdComplete(chain.td_status);

    framelist[0] = 0x0001;
    delayMs(2);

    return ok;
}

fn getDeviceDesc(dev_addr: u8, buf: []u8) bool {
    const req = UsbSetupPacket{
        .bmRequestType = 0x80 | RequestTypeStandard | RequestRecipientDevice,
        .bRequest = USB_DEVREQ_GET_DESCRIPTOR,
        .wValue = USB_DT_DEVICE << 8,
        .wIndex = 0,
        .wLength = @as(u16, @intCast(buf.len)),
    };
    return controlTransfer(dev_addr, &req, buf, PID_IN);
}

fn setAddress(old_addr: u8, new_addr: u8) bool {
    const req = UsbSetupPacket{
        .bmRequestType = RequestTypeStandard | RequestRecipientDevice,
        .bRequest = USB_DEVREQ_SET_ADDRESS,
        .wValue = new_addr,
        .wIndex = 0,
        .wLength = 0,
    };
    return controlTransfer(old_addr, &req, null, PID_OUT);
}

fn setConfiguration(dev_addr: u8, config: u8) bool {
    const req = UsbSetupPacket{
        .bmRequestType = RequestTypeStandard | RequestRecipientDevice,
        .bRequest = USB_DEVREQ_SET_CONFIG,
        .wValue = config,
        .wIndex = 0,
        .wLength = 0,
    };
    return controlTransfer(dev_addr, &req, null, PID_OUT);
}

fn getConfigDesc(dev_addr: u8, buf: []u8) bool {
    const req = UsbSetupPacket{
        .bmRequestType = 0x80 | RequestTypeStandard | RequestRecipientDevice,
        .bRequest = USB_DEVREQ_GET_DESCRIPTOR,
        .wValue = USB_DT_CONFIG << 8,
        .wIndex = 0,
        .wLength = @as(u16, @intCast(buf.len)),
    };
    return controlTransfer(dev_addr, &req, buf, PID_IN);
}

fn setProtocol(dev_addr: u8, iface: u8, protocol: u8) bool {
    const req = UsbSetupPacket{
        .bmRequestType = 0x00 | RequestTypeClass | RequestRecipientInterface,
        .bRequest = USB_DEVREQ_SET_PROTOCOL,
        .wValue = protocol,
        .wIndex = iface,
        .wLength = 0,
    };
    return controlTransfer(dev_addr, &req, null, PID_OUT);
}

fn setIdle(dev_addr: u8, iface: u8, duration: u8) bool {
    const req = UsbSetupPacket{
        .bmRequestType = 0x00 | RequestTypeClass | RequestRecipientInterface,
        .bRequest = USB_DEVREQ_SET_IDLE,
        .wValue = (@as(u16, duration) << 8),
        .wIndex = iface,
        .wLength = 0,
    };
    return controlTransfer(dev_addr, &req, null, PID_OUT);
}

fn parseInterfaceDesc(data: []const u8) ?struct { iface: UsbInterfaceDesc, endp: UsbEndpointDesc } {
    var off: usize = 0;
    while (off < data.len) {
        const len = data[off];
        if (len < 2) break;
        const dtype = data[off + 1];

        if (dtype == 4 and off + @sizeOf(UsbInterfaceDesc) <= data.len) {
            const iface = @as(*const UsbInterfaceDesc, @ptrCast(@alignCast(&data[off]))).*;
            if (iface.bInterfaceClass == USB_CLASS_HID and
                iface.bInterfaceSubClass == USB_SUBCLASS_BOOT and
                iface.bInterfaceProtocol == USB_PROTOCOL_KEYBOARD)
            {
                var endp_off = off + iface.bLength;
                while (endp_off < data.len and data[endp_off] >= 2) {
                    const elen = data[endp_off];
                    const etype = data[endp_off + 1];
                    if (etype == 5 and endp_off + @sizeOf(UsbEndpointDesc) <= data.len) {
                        const ep = @as(*const UsbEndpointDesc, @ptrCast(@alignCast(&data[endp_off]))).*;
                        if (ep.bEndpointAddress & 0x80 != 0) {
                            return .{ .iface = iface, .endp = ep };
                        }
                    }
                    if (elen < 2) break;
                    endp_off += elen;
                }
            }
        }
        if (len < 2) break;
        off += len;
    }
    return null;
}

const HID_KEYBOARD_QUEUE_SIZE = 32;
var key_queue: [HID_KEYBOARD_QUEUE_SIZE]u8 = [_]u8{0} ** HID_KEYBOARD_QUEUE_SIZE;
var key_queue_head: usize = 0;
var key_queue_tail: usize = 0;
var keyboard_dev_addr: u8 = 0;
var keyboard_endp: u8 = 0;
var keyboard_interval: u8 = 0;

var interrupt_td: *Td = undefined;
var interrupt_qh: *Qh = undefined;
var report_buf: [8]u8 = [_]u8{0} ** 8;

fn tryEnumerateKeyboard(port: u8) bool {
    uhciPortReset(port);
    uhciPortEnable(port);

    var dev_desc_buf: [18]u8 = undefined;
    var short_desc: [8]u8 = undefined;

    if (!getDeviceDesc(0, &short_desc)) return false;
    delayMs(5);

    if (!setAddress(0, 1)) return false;
    delayMs(5);
    keyboard_dev_addr = 1;

    if (!getDeviceDesc(1, &dev_desc_buf)) return false;
    delayMs(5);

    var config_buf: [256]u8 = undefined;
    if (!getConfigDesc(1, &config_buf)) return false;
    delayMs(5);

    const info = parseInterfaceDesc(&config_buf) orelse return false;
    keyboard_endp = info.endp.bEndpointAddress & 0x0F;
    keyboard_interval = if (isLowSpeed(port)) @as(u8, 8) else info.endp.bInterval;

    if (!setConfiguration(1, 1)) return false;
    delayMs(5);

    if (!setProtocol(1, info.iface.bInterfaceNumber, 0)) return false;
    delayMs(5);

    _ = setIdle(1, info.iface.bInterfaceNumber, 0);
    delayMs(5);

    return true;
}

fn setupInterruptRead() void {
    td_pool_idx = 0;
    qh_pool_idx = 0;
    _ = allocQh();

    interrupt_td = allocTd();
    @memset(@as(*[32]u8, @ptrCast(interrupt_td)), 0);
    interrupt_td.buffer = virtToPhys(&report_buf);
    interrupt_td.link = 0x0001;
    interrupt_td.token = TD_TOKEN_ACTIVE | TD_TOGGLE_DATA0 |
        (@as(u32, keyboard_dev_addr) << 8) |
        (@as(u32, keyboard_endp) << 15) |
        TD_TOKEN_IN |
        (@as(u32, @sizeOf(@TypeOf(report_buf))) & 0x7FF);

    interrupt_qh = allocQh();
    const td_addr = virtToPhys(interrupt_td);
    interrupt_qh.head_link = td_addr | 0x0002 | 0x0004;
    interrupt_qh.element_link = td_addr | 0x0002;

    var i: usize = 0;
    while (i < UHCI_FRAMELIST_SIZE) {
        framelist[i] = virtToPhys(interrupt_qh) | 0x0002;
        i += keyboard_interval;
    }
}

pub fn isInitialized() bool {
    return kb_state.initialized;
}

pub fn init() void {
    if (builtin.target.cpu.arch != .x86_64) return;

    if (!uhciPciInit()) return;
    uhciReset();

    const port = uhciPortDetect() orelse return;
    if (!tryEnumerateKeyboard(port)) return;
    setupInterruptRead();

    kb_state.initialized = true;
}

fn pollReport() bool {
    if (interrupt_td.token & TD_TOKEN_ACTIVE != 0) return false;
    const ok = interrupt_td.token & (TD_TOKEN_STALLED | TD_TOKEN_BABBLE | TD_TOKEN_ERR) == 0;
    if (!ok) {
        interrupt_td.token |= TD_TOKEN_ACTIVE;
        interrupt_td.token &= ~(@as(u32, 0xFF) << 23);
        return false;
    }

    @memcpy(@as(*[1]u8, @ptrCast(&kb_state.prev_modifiers)), @as(*const [1]u8, @ptrCast(&kb_state.modifiers)));
    @memcpy(@as(*[6]u8, @ptrCast(&kb_state.prev_keys)), @as(*const [6]u8, @ptrCast(&kb_state.keys)));
    kb_state.modifiers = report_buf[0];
    @memcpy(&kb_state.keys, report_buf[2..8]);

    const mod = kb_state.modifiers;
    kb_state.shift = (mod & 0x22) != 0;
    kb_state.ctrl = (mod & 0x11) != 0;
    kb_state.alt = (mod & (0x04 | 0x40)) != 0;

    interrupt_td.token |= TD_TOKEN_ACTIVE;
    interrupt_td.token &= ~(@as(u32, 0xFF) << 23);
    interrupt_td.token &= ~@as(u32, TD_TOGGLE_DATA0);
    interrupt_td.token &= ~@as(u32, TD_TOGGLE_DATA1);

    return true;
}

pub fn readScanCode() u8 {
    if (!kb_state.initialized) return 0;

    _ = pollReport();

    for (0..6) |i| {
        if (kb_state.keys[i] == 0) continue;
        var already = false;
        for (0..6) |j| {
            if (kb_state.prev_keys[j] == kb_state.keys[i]) {
                already = true;
                break;
            }
        }
        if (!already) {
            kb_state.last_key = kb_state.keys[i];
            if (kb_state.keys[i] == 0x39) {
                kb_state.caps = !kb_state.caps;
            }
            return kb_state.keys[i];
        }
    }

    _ = &kb_state;
    return 0;
}

pub fn getSpecialKey(sc: u8) ?enum { up, down, left, right, home, end, pgup, pgdn, del } {
    return switch (sc) {
        0x52 => .up,
        0x51 => .down,
        0x50 => .left,
        0x4F => .right,
        0x4A => .home,
        0x4D => .end,
        0x4B => .pgup,
        0x4E => .pgdn,
        0x4C => .del,
        else => null,
    };
}

pub fn scanToAscii(hid_usage: u8) u8 {
    const base: u8 = switch (hid_usage) {
        0x04 => 'a',
        0x05 => 'b',
        0x06 => 'c',
        0x07 => 'd',
        0x08 => 'e',
        0x09 => 'f',
        0x0A => 'g',
        0x0B => 'h',
        0x0C => 'i',
        0x0D => 'j',
        0x0E => 'k',
        0x0F => 'l',
        0x10 => 'm',
        0x11 => 'n',
        0x12 => 'o',
        0x13 => 'p',
        0x14 => 'q',
        0x15 => 'r',
        0x16 => 's',
        0x17 => 't',
        0x18 => 'u',
        0x19 => 'v',
        0x1A => 'w',
        0x1B => 'x',
        0x1C => 'y',
        0x1D => 'z',
        0x1E => '1',
        0x1F => '2',
        0x20 => '3',
        0x21 => '4',
        0x22 => '5',
        0x23 => '6',
        0x24 => '7',
        0x25 => '8',
        0x26 => '9',
        0x27 => '0',
        0x28 => '\n',
        0x29 => 0x1B,
        0x2A => 0x08,
        0x2B => '\t',
        0x2C => ' ',
        0x2D => '-',
        0x2E => '=',
        0x2F => '[',
        0x30 => ']',
        0x31 => '\\',
        0x33 => ';',
        0x34 => '\'',
        0x35 => '`',
        0x36 => ',',
        0x37 => '.',
        0x38 => '/',
        else => 0,
    };
    if (base == 0) return 0;
    const upper = kb_state.shift != kb_state.caps;
    return if (upper) toUpper(base) else base;
}

fn toUpper(ch: u8) u8 {
    return switch (ch) {
        'a'...'z' => ch - 32,
        '1' => '!', '2' => '@', '3' => '#', '4' => '$', '5' => '%',
        '6' => '^', '7' => '&', '8' => '*', '9' => '(', '0' => ')',
        '-' => '_', '=' => '+', '[' => '{', ']' => '}', '\\' => '|',
        ';' => ':', '\'' => '"', ',' => '<', '.' => '>', '/' => '?',
        '`' => '~',
        else => ch,
    };
}

test "usb keyboard init" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;
}

test "usb hid usage to ascii" {
    kb_state.shift = false;
    kb_state.caps = false;
    try std.testing.expectEqual(@as(u8, 'a'), scanToAscii(0x04));
    try std.testing.expectEqual(@as(u8, '1'), scanToAscii(0x1E));
    try std.testing.expectEqual(@as(u8, '\n'), scanToAscii(0x28));
    try std.testing.expectEqual(@as(u8, 0x08), scanToAscii(0x2A));
    try std.testing.expectEqual(@as(u8, ' '), scanToAscii(0x2C));
}

test "usb hid usage with shift" {
    kb_state.shift = true;
    kb_state.caps = false;
    try std.testing.expectEqual(@as(u8, 'A'), scanToAscii(0x04));
    try std.testing.expectEqual(@as(u8, '!'), scanToAscii(0x1E));
    kb_state.shift = false;
}

test "usb hid usage with caps" {
    kb_state.shift = false;
    kb_state.caps = true;
    try std.testing.expectEqual(@as(u8, 'A'), scanToAscii(0x04));
    try std.testing.expectEqual(@as(u8, '1'), scanToAscii(0x1E));
    kb_state.caps = false;
}

test "usb scan code 0 returns 0" {
    kb_state.shift = false;
    try std.testing.expectEqual(@as(u8, 0), scanToAscii(0x00));
}

test "usb get special key" {
    try std.testing.expect(getSpecialKey(0x52) != null);
    try std.testing.expect(getSpecialKey(0x00) == null);
}
