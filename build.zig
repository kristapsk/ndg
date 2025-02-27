const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip output binary; default: false") orelse false;
    const drv = b.option(DriverTarget, "driver", "display and input drivers combo; default: x11") orelse .x11;
    const disp_horiz = b.option(u32, "horiz", "display horizontal pixels count; default: 800") orelse 800;
    const disp_vert = b.option(u32, "vert", "display vertical pixels count; default: 480") orelse 480;
    const lvgl_loglevel = b.option(LVGLLogLevel, "lvgl_loglevel", "LVGL lib logging level") orelse LVGLLogLevel.default(optimize);
    const inver = b.option([]const u8, "version", "semantic version of the build; must match git tag when available");

    const buildopts = b.addOptions();
    const buildopts_mod = buildopts.createModule();
    buildopts.addOption(DriverTarget, "driver", drv);
    const semver_step = VersionStep.create(b, buildopts, inver);
    buildopts.step.dependOn(semver_step);

    // network interface (nif) standalone library used by the daemon and tests.
    const libnif_dep = b.lazyDependency("nif", .{ .target = target, .optimize = optimize }) orelse return;
    const libnif = libnif_dep.artifact("nif");
    // ini file format parser
    const libini_dep = b.lazyDependency("ini", .{ .target = target, .optimize = optimize }) orelse return;

    const common_cflags = .{
        "-Wall",
        "-Wextra",
        "-Wundef",
        // strip source file paths for repro builds
        b.fmt("-ffile-prefix-map={s}/=/", .{b.pathFromRoot("")}),
    };

    // gui build
    const ngui = b.addExecutable(.{
        .name = "ngui",
        .root_source_file = b.path("src/ngui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    ngui.pie = true;
    ngui.root_module.addImport("build_options", buildopts_mod);
    ngui.addIncludePath(b.path("lib"));
    ngui.addIncludePath(b.path("src/ui/c"));

    const lvgl_flags = .{
        "-std=c11",
        "-fstack-protector",
        "-Wformat",
        "-Wformat-security",
    } ++ common_cflags;
    ngui.addCSourceFiles(.{ .files = lvgl_generic_src, .flags = &lvgl_flags });

    const ngui_cflags = .{
        "-std=c11",
        "-Wshadow",
        "-Wunused-parameter",
        "-Werror",
    } ++ common_cflags;
    ngui.addCSourceFiles(.{
        .root = b.path("src/ui/c"),
        .files = &.{
            "ui.c",
            "lv_font_courierprimecode_14.c",
            "lv_font_courierprimecode_16.c",
            "lv_font_courierprimecode_24.c",
        },
        .flags = &ngui_cflags,
    });

    ngui.root_module.addCMacro("NM_DISP_HOR", b.fmt("{d}", .{disp_horiz}));
    ngui.root_module.addCMacro("NM_DISP_VER", b.fmt("{d}", .{disp_vert}));
    ngui.defineCMacro("LV_CONF_INCLUDE_SIMPLE", "1");
    ngui.defineCMacro("LV_LOG_LEVEL", lvgl_loglevel.text());
    ngui.defineCMacro("LV_TICK_CUSTOM", "1");
    ngui.defineCMacro("LV_TICK_CUSTOM_INCLUDE", "\"lv_custom_tick.h\"");
    ngui.defineCMacro("LV_TICK_CUSTOM_SYS_TIME_EXPR", "(nm_get_curr_tick())");
    switch (drv) {
        .sdl2 => {
            ngui.addCSourceFiles(.{ .files = lvgl_sdl2_src, .flags = &lvgl_flags });
            ngui.addCSourceFile(.{ .file = b.path("src/ui/c/drv_sdl2.c"), .flags = &ngui_cflags });
            ngui.defineCMacro("USE_SDL", "1");
            ngui.linkSystemLibrary("SDL2");
        },
        .x11 => {
            ngui.addCSourceFiles(.{ .files = lvgl_x11_src, .flags = &lvgl_flags });
            ngui.addCSourceFiles(.{
                .files = &.{
                    "src/ui/c/drv_x11.c",
                    "src/ui/c/mouse_cursor_icon.c",
                },
                .flags = &ngui_cflags,
            });
            ngui.defineCMacro("USE_X11", "1");
            ngui.linkSystemLibrary("X11");
        },
        .fbev => {
            ngui.addCSourceFiles(.{ .files = lvgl_fbev_src, .flags = &lvgl_flags });
            ngui.addCSourceFile(.{ .file = b.path("src/ui/c/drv_fbev.c"), .flags = &ngui_cflags });
            ngui.defineCMacro("USE_FBDEV", "1");
            ngui.defineCMacro("USE_EVDEV", "1");
        },
    }

    const ngui_build_step = b.step("ngui", "build ngui (nakamochi gui)");
    ngui_build_step.dependOn(&b.addInstallArtifact(ngui, .{}).step);

    // daemon build
    const nd = b.addExecutable(.{
        .name = "nd",
        .root_source_file = b.path("src/nd.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    nd.pie = true;
    nd.root_module.addImport("build_options", buildopts_mod);
    nd.root_module.addImport("nif", libnif_dep.module("nif"));
    nd.root_module.addImport("ini", libini_dep.module("ini"));
    nd.linkLibrary(libnif);

    const nd_build_step = b.step("nd", "build nd (nakamochi daemon)");
    nd_build_step.dependOn(&b.addInstallArtifact(nd, .{}).step);

    // automated tests
    {
        const tests = b.addTest(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .filter = b.option([]const u8, "test-filter", "run tests matching the filter"),
        });
        tests.root_module.addImport("build_options", buildopts_mod);
        tests.root_module.addImport("nif", libnif_dep.module("nif"));
        tests.root_module.addImport("ini", libini_dep.module("ini"));
        tests.linkLibrary(libnif);

        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "run tests");
        test_step.dependOn(&run_tests.step);
    }

    // GUI playground
    {
        const guiplay = b.addExecutable(.{
            .name = "guiplay",
            .root_source_file = b.path("src/test/guiplay.zig"),
            .target = target,
            .optimize = optimize,
        });
        guiplay.root_module.addImport("comm", b.createModule(.{ .root_source_file = b.path("src/comm.zig") }));

        const guiplay_build_step = b.step("guiplay", "build GUI playground");
        guiplay_build_step.dependOn(&b.addInstallArtifact(guiplay, .{}).step);
        guiplay_build_step.dependOn(ngui_build_step);
    }

    // bitcoind RPC client playground
    {
        const btcrpc = b.addExecutable(.{
            .name = "btcrpc",
            .root_source_file = b.path("src/test/btcrpc.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        btcrpc.root_module.addImport("bitcoindrpc", b.createModule(.{ .root_source_file = b.path("src/bitcoindrpc.zig") }));

        const btcrpc_build_step = b.step("btcrpc", "bitcoind RPC client playground");
        btcrpc_build_step.dependOn(&b.addInstallArtifact(btcrpc, .{}).step);
    }

    // lnd HTTP API client playground
    {
        const lndhc = b.addExecutable(.{
            .name = "lndhc",
            .root_source_file = b.path("src/test/lndhc.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        lndhc.root_module.addImport("lightning", b.createModule(.{ .root_source_file = b.path("src/lightning.zig") }));

        const lndhc_build_step = b.step("lndhc", "lnd HTTP API client playground");
        lndhc_build_step.dependOn(&b.addInstallArtifact(lndhc, .{}).step);
    }

    // default build step
    const build_all_step = b.step("all", "build nd and ngui (default step)");
    build_all_step.dependOn(ngui_build_step);
    build_all_step.dependOn(nd_build_step);
    b.default_step.dependOn(build_all_step);
}

const DriverTarget = enum {
    sdl2,
    x11,
    fbev, // framebuffer + evdev
};

const lvgl_sdl2_src: []const []const u8 = &.{
    "lib/lv_drivers/sdl/sdl.c",
    "lib/lv_drivers/sdl/sdl_common.c",
};

const lvgl_x11_src: []const []const u8 = &.{
    "lib/lv_drivers/x11/x11.c",
};

const lvgl_fbev_src: []const []const u8 = &.{
    "lib/lv_drivers/display/fbdev.c",
    "lib/lv_drivers/indev/evdev.c",
};

const lvgl_generic_src: []const []const u8 = &.{
    "lib/lvgl/src/core/lv_disp.c",
    "lib/lvgl/src/core/lv_event.c",
    "lib/lvgl/src/core/lv_group.c",
    "lib/lvgl/src/core/lv_indev.c",
    "lib/lvgl/src/core/lv_indev_scroll.c",
    "lib/lvgl/src/core/lv_obj.c",
    "lib/lvgl/src/core/lv_obj_class.c",
    "lib/lvgl/src/core/lv_obj_draw.c",
    "lib/lvgl/src/core/lv_obj_pos.c",
    "lib/lvgl/src/core/lv_obj_scroll.c",
    "lib/lvgl/src/core/lv_obj_style.c",
    "lib/lvgl/src/core/lv_obj_style_gen.c",
    "lib/lvgl/src/core/lv_obj_tree.c",
    "lib/lvgl/src/core/lv_refr.c",
    "lib/lvgl/src/core/lv_theme.c",
    "lib/lvgl/src/draw/arm2d/lv_gpu_arm2d.c",
    "lib/lvgl/src/draw/lv_draw.c",
    "lib/lvgl/src/draw/lv_draw_arc.c",
    "lib/lvgl/src/draw/lv_draw_img.c",
    "lib/lvgl/src/draw/lv_draw_label.c",
    "lib/lvgl/src/draw/lv_draw_layer.c",
    "lib/lvgl/src/draw/lv_draw_line.c",
    "lib/lvgl/src/draw/lv_draw_mask.c",
    "lib/lvgl/src/draw/lv_draw_rect.c",
    "lib/lvgl/src/draw/lv_draw_transform.c",
    "lib/lvgl/src/draw/lv_draw_triangle.c",
    "lib/lvgl/src/draw/lv_img_buf.c",
    "lib/lvgl/src/draw/lv_img_cache.c",
    "lib/lvgl/src/draw/lv_img_decoder.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_arc.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_bg.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_composite.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_img.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_label.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_layer.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_line.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_mask.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_polygon.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_rect.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_stack_blur.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_texture_cache.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_utils.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_arc.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_blend.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_dither.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_gradient.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_img.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_layer.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_letter.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_line.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_polygon.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_rect.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_transform.c",
    "lib/lvgl/src/extra/layouts/flex/lv_flex.c",
    "lib/lvgl/src/extra/layouts/grid/lv_grid.c",
    "lib/lvgl/src/extra/libs/bmp/lv_bmp.c",
    "lib/lvgl/src/extra/libs/ffmpeg/lv_ffmpeg.c",
    "lib/lvgl/src/extra/libs/freetype/lv_freetype.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_fatfs.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_posix.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_stdio.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_win32.c",
    "lib/lvgl/src/extra/libs/gif/gifdec.c",
    "lib/lvgl/src/extra/libs/gif/lv_gif.c",
    "lib/lvgl/src/extra/libs/png/lodepng.c",
    "lib/lvgl/src/extra/libs/png/lv_png.c",
    "lib/lvgl/src/extra/libs/qrcode/lv_qrcode.c",
    "lib/lvgl/src/extra/libs/qrcode/qrcodegen.c",
    "lib/lvgl/src/extra/libs/rlottie/lv_rlottie.c",
    "lib/lvgl/src/extra/libs/sjpg/lv_sjpg.c",
    "lib/lvgl/src/extra/libs/sjpg/tjpgd.c",
    "lib/lvgl/src/extra/lv_extra.c",
    "lib/lvgl/src/extra/others/fragment/lv_fragment.c",
    "lib/lvgl/src/extra/others/fragment/lv_fragment_manager.c",
    "lib/lvgl/src/extra/others/gridnav/lv_gridnav.c",
    "lib/lvgl/src/extra/others/ime/lv_ime_pinyin.c",
    "lib/lvgl/src/extra/others/imgfont/lv_imgfont.c",
    "lib/lvgl/src/extra/others/monkey/lv_monkey.c",
    "lib/lvgl/src/extra/others/msg/lv_msg.c",
    "lib/lvgl/src/extra/others/snapshot/lv_snapshot.c",
    "lib/lvgl/src/extra/themes/basic/lv_theme_basic.c",
    "lib/lvgl/src/extra/themes/default/lv_theme_default.c",
    "lib/lvgl/src/extra/themes/mono/lv_theme_mono.c",
    "lib/lvgl/src/extra/widgets/animimg/lv_animimg.c",
    "lib/lvgl/src/extra/widgets/calendar/lv_calendar.c",
    "lib/lvgl/src/extra/widgets/calendar/lv_calendar_header_arrow.c",
    "lib/lvgl/src/extra/widgets/calendar/lv_calendar_header_dropdown.c",
    "lib/lvgl/src/extra/widgets/chart/lv_chart.c",
    "lib/lvgl/src/extra/widgets/colorwheel/lv_colorwheel.c",
    "lib/lvgl/src/extra/widgets/imgbtn/lv_imgbtn.c",
    "lib/lvgl/src/extra/widgets/keyboard/lv_keyboard.c",
    "lib/lvgl/src/extra/widgets/led/lv_led.c",
    "lib/lvgl/src/extra/widgets/list/lv_list.c",
    "lib/lvgl/src/extra/widgets/menu/lv_menu.c",
    "lib/lvgl/src/extra/widgets/meter/lv_meter.c",
    "lib/lvgl/src/extra/widgets/msgbox/lv_msgbox.c",
    "lib/lvgl/src/extra/widgets/span/lv_span.c",
    "lib/lvgl/src/extra/widgets/spinbox/lv_spinbox.c",
    "lib/lvgl/src/extra/widgets/spinner/lv_spinner.c",
    "lib/lvgl/src/extra/widgets/tabview/lv_tabview.c",
    "lib/lvgl/src/extra/widgets/tileview/lv_tileview.c",
    "lib/lvgl/src/extra/widgets/win/lv_win.c",
    "lib/lvgl/src/font/lv_font.c",
    "lib/lvgl/src/font/lv_font_fmt_txt.c",
    "lib/lvgl/src/font/lv_font_loader.c",
    "lib/lvgl/src/hal/lv_hal_disp.c",
    "lib/lvgl/src/hal/lv_hal_indev.c",
    "lib/lvgl/src/hal/lv_hal_tick.c",
    "lib/lvgl/src/misc/lv_anim.c",
    "lib/lvgl/src/misc/lv_anim_timeline.c",
    "lib/lvgl/src/misc/lv_area.c",
    "lib/lvgl/src/misc/lv_async.c",
    "lib/lvgl/src/misc/lv_bidi.c",
    "lib/lvgl/src/misc/lv_color.c",
    "lib/lvgl/src/misc/lv_fs.c",
    "lib/lvgl/src/misc/lv_gc.c",
    "lib/lvgl/src/misc/lv_ll.c",
    "lib/lvgl/src/misc/lv_log.c",
    "lib/lvgl/src/misc/lv_lru.c",
    "lib/lvgl/src/misc/lv_math.c",
    "lib/lvgl/src/misc/lv_mem.c",
    "lib/lvgl/src/misc/lv_printf.c",
    "lib/lvgl/src/misc/lv_style.c",
    "lib/lvgl/src/misc/lv_style_gen.c",
    "lib/lvgl/src/misc/lv_templ.c",
    "lib/lvgl/src/misc/lv_timer.c",
    "lib/lvgl/src/misc/lv_tlsf.c",
    "lib/lvgl/src/misc/lv_txt.c",
    "lib/lvgl/src/misc/lv_txt_ap.c",
    "lib/lvgl/src/misc/lv_utils.c",
    "lib/lvgl/src/widgets/lv_arc.c",
    "lib/lvgl/src/widgets/lv_bar.c",
    "lib/lvgl/src/widgets/lv_btn.c",
    "lib/lvgl/src/widgets/lv_btnmatrix.c",
    "lib/lvgl/src/widgets/lv_canvas.c",
    "lib/lvgl/src/widgets/lv_checkbox.c",
    "lib/lvgl/src/widgets/lv_dropdown.c",
    "lib/lvgl/src/widgets/lv_img.c",
    "lib/lvgl/src/widgets/lv_label.c",
    "lib/lvgl/src/widgets/lv_line.c",
    "lib/lvgl/src/widgets/lv_objx_templ.c",
    "lib/lvgl/src/widgets/lv_roller.c",
    "lib/lvgl/src/widgets/lv_slider.c",
    "lib/lvgl/src/widgets/lv_switch.c",
    "lib/lvgl/src/widgets/lv_table.c",
    "lib/lvgl/src/widgets/lv_textarea.c",
};

/// LVGL log levels based on LV_LOG_LEVEL_xxx.
/// note that the messages are printed from a zig fn callback, always with .info std.log.Level.
const LVGLLogLevel = enum {
    trace,
    info,
    warn,
    err,
    user,
    none,

    /// returns default mode based on the compiler optimization flags.
    fn default(mode: std.builtin.Mode) @This() {
        return switch (mode) {
            .Debug => .warn,
            .ReleaseSafe => .warn,
            .ReleaseFast, .ReleaseSmall => .err,
        };
    }

    /// returns a C #define value for LVGL config.
    fn text(self: @This()) []const u8 {
        return switch (self) {
            .trace => "LV_LOG_LEVEL_TRACE",
            .info => "LV_LOG_LEVEL_INFO",
            .warn => "LV_LOG_LEVEL_WARN",
            .err => "LV_LOG_LEVEL_ERROR",
            .user => "LV_LOG_LEVEL_USER",
            .none => "LV_LOG_LEVEL_NONE",
        };
    }
};

/// VersionStep injects a release build semantic version into buildopts as "semver".
/// the make step fails if the inver input version and the one found in a git tag mismatch.
///
/// while git-tagged versions are expected to be in v<semver>format, input version
/// to match against is any format supported by std.SemanticVersion.parse.
/// input version is optional; if unset, make fn succeeds given a correctly formatted
/// git tag is found.
const VersionStep = struct {
    inver: ?[]const u8, // input version in std.SemanticVersion.parse format
    buildopts: *std.Build.Step.Options, // where to store the build version

    b: *std.Build,
    step: std.Build.Step,

    fn create(b: *std.Build, o: *std.Build.Step.Options, inver: ?[]const u8) *std.Build.Step {
        const vstep = b.allocator.create(VersionStep) catch unreachable;
        vstep.* = VersionStep{
            .inver = inver,
            .buildopts = o,
            .b = b,
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "VersionStep: ndg semver",
                .owner = b,
                .makeFn = make,
            }),
        };
        return &vstep.step;
    }

    fn make(step: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
        const self: *@This() = @fieldParentPtr("step", step);
        const semver = try self.eval();
        std.log.info("build version: {any}", .{semver});
        self.buildopts.addOption(std.SemanticVersion, "semver", semver);
    }

    fn eval(self: *VersionStep) !std.SemanticVersion {
        const repover = try self.gitver();
        if (self.inver) |v| {
            const insem = std.SemanticVersion.parse(v) catch |err| {
                std.log.err("invalid input semver '{s}': {any}", .{ v, err });
                return err;
            };
            if (repover != null and insem.order(repover.?) != .eq) {
                std.log.err("input and repo semver mismatch: {any} vs {any}", .{ insem, repover });
                return error.VersionMismatch;
            }
            return insem;
        }

        if (repover == null) {
            std.log.err("must supply build semver from command line.", .{});
            return error.MissingVersion;
        }
        return repover.?;
    }

    fn gitver(self: *VersionStep) !?std.SemanticVersion {
        if (!std.process.can_spawn) {
            return null;
        }
        const git = self.b.findProgram(&[_][]const u8{"git"}, &[_][]const u8{}) catch return null;

        const prefix = "v"; // git tag prefix
        const matchTag = self.b.fmt("{s}*.*.*", .{prefix});
        const cmd = [_][]const u8{ git, "-C", self.b.pathFromRoot("."), "describe", "--match", matchTag, "--tags", "--abbrev=8" };
        var code: u8 = undefined;
        const git_describe = self.b.runAllowFail(&cmd, &code, .Ignore) catch return null;
        const repotag = std.mem.trim(u8, git_describe, " \n\r")[prefix.len..];
        return std.SemanticVersion.parse(repotag) catch |err| ret: {
            std.log.err("unparsable git tag semver '{s}': {any}", .{ repotag, err });
            break :ret err;
        };
    }
};
