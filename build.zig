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

    const optimize = b.standardOptimizeOption(.{});

    const server_module = b.createModule(.{
        .root_source_file = b.path("src/tools/server/root.zig"),
        .target = b.graph.host,
    });

    const launcher_module = b.createModule(.{
        .root_source_file = b.path("src/tools/launcher/root.zig"),
        .target = b.graph.host,
    });
    launcher_module.addImport("server", server_module);
    const launcher_exe = b.addExecutable(.{
        .root_module = launcher_module,
        .name = "launcher",
    });
    const install_launcher = b.addInstallArtifact(launcher_exe, .{});

    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = wii_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/benchmark/root.zig"),
        .target = wii_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const common_module = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = wii_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wii_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = wii_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("src/test/test_runner.zig"),
        },
        .emit_object = true,
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

        const objects = .{
            b.addObject(.{ .name = APPLICATION_NAME, .root_module = module }),
            unit_tests,
            b.addObject(.{ .name = "platform", .root_module = platform_module }),
            b.addObject(.{ .name = "benchmark", .root_module = benchmark_module }),
            b.addObject(.{ .name = "common", .root_module = common_module }),
        };

        inline for (objects, 0..) |obj, idx| {
            obj.root_module.stack_check = false;
            obj.root_module.stack_protector = false;
            obj.root_module.sanitize_thread = false;
            obj.root_module.red_zone = false;
            obj.root_module.omit_frame_pointer = false;
            obj.root_module.valgrind = false;
            obj.root_module.unwind_tables = null;
            obj.root_module.single_threaded = true;
            obj.setLibCFile(libc_txt);

            obj.root_module.addSystemIncludePath(wii.path("devkitPPC/powerpc-eabi/include"));
            obj.root_module.addSystemIncludePath(wii.path("libogc/include"));

            obj.root_module.addCMacro("__wii__", "1");
            obj.root_module.addCMacro("HW_RVL", "1");
            switch (idx) {
                0, 1, 4 => {
                    obj.root_module.addImport("platform", platform_module);
                    obj.root_module.addImport("benchmark", benchmark_module);
                    obj.root_module.addImport("common", common_module);
                },
                2 => {},
                3 => {
                    obj.root_module.addImport("platform", platform_module);
                    obj.root_module.addImport("common", common_module);
                },
                else => @compileError("too many objects!"),
            }
        }

        unit_tests.addSystemIncludePath(wii.path("devkitPPC/powerpc-eabi/include"));
        unit_tests.addSystemIncludePath(wii.path("libogc/include"));

        const ext = if (host.os.tag == .windows) ".exe" else "";
        const gcc_path = wii.path(b.fmt("devkitPPC/bin/powerpc-eabi-gcc{s}", .{ext})).getPath(b);
        const elf2dol_path = wii.path(b.fmt("tools/bin/elf2dol{s}", .{ext})).getPath(b);
        const libogc_lib = b.fmt("-L{s}", .{wii.path("libogc/lib/wii").getPath(b)});

        inline for (objects, 0..) |obj, idx| {
            switch (idx) {
                0, 1 => {
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
                    const elf_path = try std.fmt.allocPrint(b.allocator, "{s}.elf", .{obj.name});
                    const dol_path = try std.fmt.allocPrint(b.allocator, "{s}.dol", .{obj.name});
                    const elf_output = elf_cmd.addOutputFileArg(elf_path);

                    const dol_cmd = b.addSystemCommand(&.{elf2dol_path});
                    dol_cmd.addFileArg(elf_output);
                    const dol_output = dol_cmd.addOutputFileArg(dol_path);
                    const install_elf = b.addInstallFile(elf_output, elf_path);
                    const install_dol = b.addInstallFile(dol_output, dol_path);

                    switch (idx) {
                        0 => {
                            b.getInstallStep().dependOn(&install_elf.step);
                            b.getInstallStep().dependOn(&install_dol.step);

                            const deploy_step = b.step("deploy", "Deploy to wii");
                            const deploy_launcher_cmd = b.addRunArtifact(launcher_exe);
                            deploy_launcher_cmd.addArg("deploy");
                            deploy_launcher_cmd.step.dependOn(&install_dol.step);
                            deploy_launcher_cmd.step.dependOn(&install_elf.step);
                            deploy_launcher_cmd.step.dependOn(&install_launcher.step);
                            deploy_step.dependOn(&deploy_launcher_cmd.step);

                            const run_step = b.step("run", "Run in dolphin");
                            const run_launcher_cmd = b.addRunArtifact(launcher_exe);
                            run_launcher_cmd.step.dependOn(&install_dol.step);
                            run_launcher_cmd.step.dependOn(&install_elf.step);
                            run_launcher_cmd.step.dependOn(&install_launcher.step);
                            run_step.dependOn(&run_launcher_cmd.step);
                        },
                        1 => {
                            const test_step = b.step("test", "Run tests in dolphin");
                            const run = b.addSystemCommand(&.{ "dolphin-emu-nogui", "-p", "headless", "zig-out/test.dol" });
                            test_step.dependOn(&run.step);
                            run.step.dependOn(&unit_tests.step);
                            run.step.dependOn(&install_elf.step);
                            run.step.dependOn(&install_dol.step);
                        },
                        else => {
                            @compileError("too many objects!");
                        },
                    }
                },
                else => {},
            }
        }
    }
}
