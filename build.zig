const std = @import("std");
const builtin = @import("builtin");
const host = builtin.target;

const APPLICATION_NAME = "wii-zig";
const WII_DEV = "wii_dev_" ++ @tagName(host.os.tag) ++ "_" ++ @tagName(host.cpu.arch);

pub fn build(b: *std.Build) !void {
    const wii_target = b.resolveTargetQuery(.{
        .ofmt = .elf,
        .os_tag = .freestanding,
        .cpu_arch = .powerpc,
        .cpu_model = .{ .explicit = &std.Target.powerpc.cpu.@"750" },
        .cpu_features_add = std.Target.powerpc.featureSet(&.{.hard_float}),
        .abi = .eabihf,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wii_target,
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
        .link_libcpp = false,
    });

    if (b.lazyDependency(WII_DEV, .{})) |wii| {
        const libc_file = b.addWriteFiles();
        const libc_include_path = wii.path("devkitPPC/powerpc-eabi/include").getPath(b);
        const crt_path = wii.path("devkitPPC/powerpc-eabi/lib").getPath(b);
        const libc_contents = b.fmt(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\gcc_dir=
        , .{ libc_include_path, libc_include_path, crt_path });
        const libc_txt = libc_file.add("libc.txt", libc_contents);

        const obj = b.addObject(.{ .name = APPLICATION_NAME, .root_module = module });
        obj.root_module.stack_check = false;
        obj.root_module.stack_protector = false;
        obj.root_module.sanitize_thread = false;
        obj.root_module.red_zone = false;
        obj.root_module.omit_frame_pointer = false;
        obj.root_module.valgrind = false;
        obj.root_module.unwind_tables = null;
        obj.root_module.single_threaded = true;
        obj.setLibCFile(libc_txt);

        module.addSystemIncludePath(wii.path("devkitPPC/powerpc-eabi/include"));
        module.addSystemIncludePath(wii.path("libogc/include"));

        module.addCMacro("__wii__", "1");
        module.addCMacro("HW_RVL", "1");

        const ext = if (host.os.tag == .windows) ".exe" else "";
        const gcc_path = wii.path(b.fmt("devkitPPC/bin/powerpc-eabi-gcc{s}", .{ext})).getPath(b);
        const elf2dol_path = wii.path(b.fmt("tools/bin/elf2dol{s}", .{ext})).getPath(b);
        const libogc_lib = b.fmt("-L{s}", .{wii.path("libogc/lib/wii").getPath(b)});

        const elf_cmd = b.addSystemCommand(&.{gcc_path});
        elf_cmd.addFileArg(obj.getEmittedBin());
        elf_cmd.addArgs(&.{
            "-g",
            "-DGEKKO",
            "-mrvl",
            "-mcpu=750",
            "-meabi",
            "-mhard-float",
            "-Wl,-Map,zig-out/.map",
            "-Wl,-z,noexecstack",
            libogc_lib,
            "-lwiiuse",
            "-lbte",
            "-logc",
            "-lm",
            "-o",
        });
        const elf_output = elf_cmd.addOutputFileArg(APPLICATION_NAME ++ ".elf");

        const dol_cmd = b.addSystemCommand(&.{elf2dol_path});
        dol_cmd.addFileArg(elf_output);
        const dol_output = dol_cmd.addOutputFileArg(APPLICATION_NAME ++ ".dol");

        const install_elf = b.addInstallFile(elf_output, APPLICATION_NAME ++ ".elf");
        const install_dol = b.addInstallFile(dol_output, APPLICATION_NAME ++ ".dol");
        b.getInstallStep().dependOn(&install_elf.step);
        b.getInstallStep().dependOn(&install_dol.step);
    }
}
