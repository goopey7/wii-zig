pub const c = @cImport({
    @cInclude("gccore.h");
    @cInclude("ogc/system.h");
    @cInclude("tuxedo/ppc/context.h");
    @cInclude("tuxedo/ppc/exception.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("network.h");
    @cInclude("tuxedo/ppc/clock.h");
});

pub const wpad = @cImport({
    @cInclude("gccore.h");
    @cInclude("ogc/system.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("network.h");
    @cInclude("tuxedo/ppc/clock.h");
    @cInclude("wiiuse/wpad.h");
});

