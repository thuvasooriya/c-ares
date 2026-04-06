const std = @import("std");
const builtin = @import("builtin");
const build_zon = @import("build.zig.zon");
const zbh = @import("zig_build_helper");

comptime {
    zbh.checkZigVersion("0.15.2");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.option(bool, "shared", "Build shared library") orelse false;
    const tools = b.option(bool, "tools", "Build adig and ahost tools") orelse true;
    const threads = b.option(bool, "threads", "Enable threaded/event-thread support") orelse true;
    const use_macos_sdk = b.option(bool, "use_macos_sdk", "Use macOS SDK headers (default: auto-detect)") orelse blk: {
        // Auto-detect: use SDK for all Darwin builds (native or cross)
        const platform = zbh.Platform.detect(target.result);
        break :blk platform.is_darwin;
    };

    if (!threads) {
        @panic("-Dthreads=false is not implemented yet in this Zig build. Use -Dthreads=true.");
    }

    const upstream = b.dependency("upstream", .{});
    
    // Get macOS SDK for Darwin builds when use_macos_sdk is true
    const macos_sdk_dep = if (use_macos_sdk) b.lazyDependency("macos_sdk_minimal", .{}) else null;

    const linkage: std.builtin.LinkMode = if (shared) .dynamic else .static;
    const lib_build = buildLibrary(b, target, optimize, upstream, linkage, use_macos_sdk, threads, macos_sdk_dep);
    b.installArtifact(lib_build.lib);

    // Install headers
    lib_build.lib.installHeadersDirectory(upstream.path("include"), "", .{});

    if (tools) {
        addTools(b, target, optimize, upstream, lib_build, linkage == .static);
    }

    // CI Step
    const ci_step = b.step("ci", "Build all CI targets");
    addCiTargets(b, ci_step);
}

pub fn buildLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream: *std.Build.Dependency,
    linkage: std.builtin.LinkMode,
    use_macos_sdk: bool,
    threads_enabled: bool,
    macos_sdk_dep: ?*std.Build.Dependency,
) LibraryBuild {
    const platform = zbh.Platform.detect(target.result);
    const src_root = upstream.path("src/lib");
    const cflags = &.{ "-std=gnu90", "-D_GNU_SOURCE" };

    const lib = b.addLibrary(.{
        .name = "cares",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = linkage,
    });

    // Add macOS SDK include paths when available
    if (macos_sdk_dep) |sdk| {
        lib.addSystemIncludePath(sdk.path("usr/include"));
        lib.addSystemFrameworkPath(sdk.path("System/Library/Frameworks"));
        lib.addSystemIncludePath(sdk.path("System/Library/Frameworks/SystemConfiguration.framework/Versions/A/Headers"));
        lib.addSystemIncludePath(sdk.path("System/Library/Frameworks/CoreFoundation.framework/Versions/A/Headers"));
    }

    // Generate ares_build.h manually
    const ares_build_h = createAresBuildH(b, platform);
    lib.addIncludePath(ares_build_h.dirname());
    lib.installHeader(ares_build_h, "ares_build.h");

    // Generate ares_config.h
    const config_h = b.addConfigHeader(
        .{
            .style = .{ .cmake = upstream.path("src/lib/ares_config.h.cmake") },
            .include_path = "ares_config.h",
        },
        .{
            .HAVE_SYS_TYPES_H = 1,
            .HAVE_SYS_STAT_H = 1,
            .HAVE_SYS_SOCKET_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_ARPA_INET_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_NETINET_IN_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_NETINET_TCP_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_NETDB_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_UNISTD_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_ERRNO_H = 1,
            .HAVE_FCNTL_H = 1,
            .HAVE_LIMITS_H = 1,
            .HAVE_STDINT_H = 1,
            .HAVE_STDLIB_H = 1,
            .HAVE_STRING_H = 1,
            .HAVE_TIME_H = 1,
            .HAVE_SYS_TIME_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_SYS_UIO_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_SIGNAL_H = 1,
            .HAVE_STRINGS_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_POLL_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_SYS_SELECT_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_SYS_EVENT_H = zbh.Config.boolToOptInt(platform.is_darwin or platform.is_bsd),
            .HAVE_SYS_EPOLL_H = zbh.Config.boolToOptInt(platform.is_linux),
            .HAVE_SYS_RANDOM_H = zbh.Config.boolToOptInt(platform.is_linux),
            .HAVE_IFADDRS_H = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_NET_IF_H = zbh.Config.boolToOptInt(platform.is_posix),

            // Windows specifics
            .HAVE_WINSOCK2_H = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_WS2TCPIP_H = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_WINDOWS_H = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_IPHLPAPI_H = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_NETIOAPI_H = zbh.Config.boolToOptInt(platform.is_windows),

            .HAVE_GETHOSTNAME = 1,
            .HAVE_GETADDRINFO = 1,
            .HAVE_FREEADDRINFO = 1,
            .HAVE_GETNAMEINFO = 1,
            .HAVE_INET_PTON = 1,
            .HAVE_INET_NTOP = 1,
            .HAVE_STRCASECMP = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_STRDUP = 1,
            .HAVE_STRICMP = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_STRNCASECMP = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_STRNICMP = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_WRITEV = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_IOCTL = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_IOCTLSOCKET = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_IOCTLSOCKET_FIONBIO = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_CLOSESOCKET = zbh.Config.boolToOptInt(platform.is_windows),
            .HAVE_STAT = 1,
            .HAVE_PIPE = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_PIPE2 = zbh.Config.boolToOptInt(platform.is_linux),
            .HAVE_POLL = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_KQUEUE = zbh.Config.boolToOptInt(platform.is_darwin or platform.is_bsd),
            .HAVE_EPOLL = zbh.Config.boolToOptInt(platform.is_linux),
            .HAVE_GETENV = 1,
            .HAVE_ARC4RANDOM_BUF = zbh.Config.boolToOptInt(platform.is_darwin or platform.is_bsd),
            .HAVE_GETRANDOM = zbh.Config.boolToOptInt(platform.is_linux),

            // gethostname type
            .GETHOSTNAME_TYPE_ARG2 = if (platform.is_windows) "int" else "size_t",

            // getnameinfo types (POSIX standard)
            .GETNAMEINFO_QUAL_ARG1 = "",
            .GETNAMEINFO_TYPE_ARG1 = if (platform.is_windows) "struct sockaddr *" else "const struct sockaddr *",
            .GETNAMEINFO_TYPE_ARG2 = if (platform.is_windows) "int" else "socklen_t",
            .GETNAMEINFO_TYPE_ARG46 = if (platform.is_windows) "DWORD" else "socklen_t",
            .GETNAMEINFO_TYPE_ARG7 = "int",

            // getservbyport_r / getservbyname_r (0 = not available or use different API)
            .GETSERVBYPORT_R_ARGS = if (platform.is_linux) @as(i32, 6) else @as(i32, 0),
            .GETSERVBYNAME_R_ARGS = if (platform.is_linux) @as(i32, 6) else @as(i32, 0),

            // recv types
            .RECV_TYPE_ARG1 = if (platform.is_windows) "SOCKET" else "int",
            .RECV_TYPE_ARG2 = if (platform.is_windows) "char *" else "void *",
            .RECV_TYPE_ARG3 = if (platform.is_windows) "int" else "size_t",
            .RECV_TYPE_ARG4 = "int",
            .RECV_TYPE_RETV = if (platform.is_windows) "int" else "ssize_t",

            // recvfrom types
            .RECVFROM_TYPE_ARG1 = if (platform.is_windows) "SOCKET" else "int",
            .RECVFROM_TYPE_ARG2 = if (platform.is_windows) "char *" else "void *",
            .RECVFROM_TYPE_ARG3 = if (platform.is_windows) "int" else "size_t",
            .RECVFROM_TYPE_ARG4 = "int",
            .RECVFROM_TYPE_ARG5 = "struct sockaddr *",
            .RECVFROM_QUAL_ARG5 = "",
            .RECVFROM_TYPE_ARG6 = if (platform.is_windows) "int *" else "socklen_t *",
            .RECVFROM_TYPE_RETV = if (platform.is_windows) "int" else "ssize_t",

            // send types
            .SEND_TYPE_ARG1 = if (platform.is_windows) "SOCKET" else "int",
            .SEND_TYPE_ARG2 = if (platform.is_windows) "const char *" else "const void *",
            .SEND_TYPE_ARG3 = if (platform.is_windows) "int" else "size_t",
            .SEND_TYPE_ARG4 = "int",
            .SEND_TYPE_RETV = if (platform.is_windows) "int" else "ssize_t",

            .HAVE_BOOL_T = 1,
            .HAVE_SOCKLEN_T = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_STRUCT_TIMEVAL = 1,
            .HAVE_STRUCT_SOCKADDR_IN6 = 1,
            .HAVE_STRUCT_ADDRINFO = 1,
            .HAVE_STRUCT_SOCKADDR_STORAGE = 1,
            .HAVE_GETTIMEOFDAY = 1,
            .HAVE_CLOCK_GETTIME_MONOTONIC = zbh.Config.boolToOptInt(platform.is_posix),
            .HAVE_PTHREAD_H = zbh.Config.boolToOptInt(threads_enabled and platform.is_posix),
            .HAVE_PTHREAD_NP_H = zbh.Config.boolToOptInt(threads_enabled and platform.is_posix),
            .CARES_THREADS = zbh.Config.boolToOptInt(threads_enabled and (platform.is_posix or platform.is_windows)),
            .HAVE_PTHREAD_INIT = zbh.Config.boolToOptInt(threads_enabled and platform.is_posix),

            .HAVE_AF_INET6 = 1,
            .HAVE_PF_INET6 = 1,
            .HAVE_FCNTL_O_NONBLOCK = zbh.Config.boolToOptInt(platform.is_posix),

            // Random file for entropy (POSIX)
            .CARES_RANDOM_FILE = if (platform.is_posix) "/dev/urandom" else null,

            .CARES_SYMBOL_HIDING = null,
            .CARES_USE_LIBRESOLV = null,
        },
    );

    lib.addConfigHeader(config_h);

    lib.addIncludePath(upstream.path("src/lib"));
    lib.addIncludePath(upstream.path("src/lib/include"));
    lib.addIncludePath(upstream.path("src/lib/event"));
    lib.addIncludePath(upstream.path("include"));

    lib.root_module.addCMacro("HAVE_CONFIG_H", "1");
    lib.root_module.addCMacro("CARES_BUILDING_LIBRARY", "1");
    if (linkage == .static) {
        lib.root_module.addCMacro("CARES_STATIC", "1");
        if (platform.is_windows) {
            lib.root_module.addCMacro("CARES_STATICLIB", "1");
        }
    }

    if (platform.is_windows) {
        lib.linkSystemLibrary("ws2_32");
        lib.linkSystemLibrary("iphlpapi");
        lib.linkSystemLibrary("advapi32");
        lib.root_module.addCMacro("_WIN32_WINNT", "0x0601");
        lib.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "1");
    } else if (platform.is_darwin) {
        // For static libraries, frameworks are linked by consuming application
        // Only link frameworks for shared libraries AND when building natively
        if (linkage == .dynamic and use_macos_sdk) {
            lib.linkFramework("SystemConfiguration");
            lib.linkFramework("CoreFoundation");
        }
        if (threads_enabled) {
            lib.linkSystemLibrary("pthread");
        }
    } else if (threads_enabled and platform.is_posix) {
        lib.linkSystemLibrary("pthread");
    }

    // When targeting macOS without SDK access, exclude files that need SDK headers
    // (notify.h, SystemConfiguration/SCNetworkConfiguration.h)
    // For cross-compilation scenarios, we provide stub implementations instead.
    if (platform.is_darwin and !use_macos_sdk) {
        const source_set = if (threads_enabled) &sources_no_macos else &sources_no_macos_no_threads;
        lib.addCSourceFiles(.{ .root = src_root, .files = source_set, .flags = cflags });

        // Create stub implementations for macOS SDK-dependent functions
        const apple_stubs = b.addWriteFiles();
        const apple_stub_source =
            \\#include "ares_private.h"
            \\#include "ares_event.h"
            \\
            \\/* Stub implementations for cross-compiled macOS builds without SDK */
            \\struct ares_event_configchg;
            \\typedef struct ares_event_configchg ares_event_configchg_t;
            \\
            \\ares_status_t ares_init_sysconfig_macos(const ares_channel_t *channel,
            \\                                        ares_sysconfig_t     *sysconfig) {
            \\  (void)channel; (void)sysconfig; return ARES_ENOTIMP;
            \\}
            \\
            \\ares_status_t ares_event_configchg_init(ares_event_configchg_t **configchg,
            \\                                        ares_event_thread_t     *e) {
            \\  (void)configchg; (void)e; return ARES_ENOTIMP;
            \\}
            \\
            \\void ares_event_configchg_destroy(ares_event_configchg_t *configchg) {
            \\  (void)configchg;
            \\}
        ;
        const apple_stub_file = apple_stubs.add("apple_stubs.c", apple_stub_source);
        lib.addCSourceFile(.{ .file = apple_stub_file, .flags = cflags });
    } else {
        const source_set = if (threads_enabled) &sources else &sources_no_threads;
        lib.addCSourceFiles(.{ .root = src_root, .files = source_set, .flags = cflags });
    }

    return .{
        .lib = lib,
        .config_h = config_h,
        .ares_build_h = ares_build_h,
    };
}

const LibraryBuild = struct {
    lib: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    ares_build_h: std.Build.LazyPath,
};

fn addTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream: *std.Build.Dependency,
    cares_build: LibraryBuild,
    link_static_lib: bool,
) void {
    const platform = zbh.Platform.detect(target.result);
    const tool_flags = &[_][]const u8{ "-std=gnu90", "-D_GNU_SOURCE", "-DHAVE_CONFIG_H", "-DCARES_NO_DEPRECATED" };
    const helper_sources = &[_][]const u8{"ares_getopt.c"};

    const ahost = b.addExecutable(.{
        .name = "ahost",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    ahost.addIncludePath(upstream.path("src/tools"));
    ahost.addIncludePath(upstream.path("src/lib"));
    ahost.addIncludePath(upstream.path("src/lib/include"));
    ahost.addIncludePath(upstream.path("include"));
    ahost.addIncludePath(cares_build.ares_build_h.dirname());
    ahost.addConfigHeader(cares_build.config_h);
    if (platform.is_windows and link_static_lib) {
        ahost.root_module.addCMacro("CARES_STATICLIB", "1");
    }
    ahost.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = &.{"ahost.c"}, .flags = tool_flags });
    ahost.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = helper_sources, .flags = tool_flags });
    ahost.linkLibrary(cares_build.lib);
    b.installArtifact(ahost);

    const adig = b.addExecutable(.{
        .name = "adig",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    adig.addIncludePath(upstream.path("src/tools"));
    adig.addIncludePath(upstream.path("src/lib"));
    adig.addIncludePath(upstream.path("src/lib/include"));
    adig.addIncludePath(upstream.path("include"));
    adig.addIncludePath(cares_build.ares_build_h.dirname());
    adig.addConfigHeader(cares_build.config_h);
    if (platform.is_windows and link_static_lib) {
        adig.root_module.addCMacro("CARES_STATICLIB", "1");
    }
    adig.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = &.{"adig.c"}, .flags = tool_flags });
    adig.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = helper_sources, .flags = tool_flags });
    adig.linkLibrary(cares_build.lib);
    b.installArtifact(adig);
}

fn createAresBuildH(b: *std.Build, platform: zbh.Platform) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    const socklen_t = if (platform.is_windows) "int" else "socklen_t";
    const ssize_t = if (platform.is_windows) "long" else "ssize_t";

    const sys_types = if (platform.is_posix) "#define CARES_HAVE_SYS_TYPES_H" else "#undef CARES_HAVE_SYS_TYPES_H";
    const sys_socket = if (platform.is_posix) "#define CARES_HAVE_SYS_SOCKET_H" else "#undef CARES_HAVE_SYS_SOCKET_H";
    const winsock2 = if (platform.is_windows) "#define CARES_HAVE_WINSOCK2_H" else "#undef CARES_HAVE_WINSOCK2_H";
    const ws2tcpip = if (platform.is_windows) "#define CARES_HAVE_WS2TCPIP_H" else "#undef CARES_HAVE_WS2TCPIP_H";
    const windows_h = if (platform.is_windows) "#define CARES_HAVE_WINDOWS_H" else "#undef CARES_HAVE_WINDOWS_H";

    const content = b.fmt(
        \\#ifndef __CARES_BUILD_H
        \\#define __CARES_BUILD_H
        \\
        \\#define CARES_TYPEOF_ARES_SOCKLEN_T {s}
        \\#define CARES_TYPEOF_ARES_SSIZE_T {s}
        \\
        \\{s}
        \\{s}
        \\{s}
        \\{s}
        \\{s}
        \\
        \\#ifdef CARES_HAVE_SYS_TYPES_H
        \\#  include <sys/types.h>
        \\#endif
        \\
        \\#ifdef CARES_HAVE_SYS_SOCKET_H
        \\#  include <sys/socket.h>
        \\#endif
        \\
        \\#ifdef CARES_HAVE_WINSOCK2_H
        \\#  include <winsock2.h>
        \\#endif
        \\
        \\#ifdef CARES_HAVE_WS2TCPIP_H
        \\#  include <ws2tcpip.h>
        \\#endif
        \\
        \\#ifdef CARES_HAVE_WINDOWS_H
        \\#  include <windows.h>
        \\#endif
        \\
        \\#endif /* __CARES_BUILD_H */
    , .{ socklen_t, ssize_t, sys_types, sys_socket, winsock2, ws2tcpip, windows_h });

    return wf.add("ares_build.h", content);
}

fn addCiTargets(b: *std.Build, ci_step: *std.Build.Step) void {
    const version = zbh.Dependencies.extractVersionFromUrl(build_zon.dependencies.upstream.url) orelse build_zon.version;

    const write_version = b.addWriteFiles();
    _ = write_version.add("version", version);
    ci_step.dependOn(&b.addInstallFile(write_version.getDirectory().path(b, "version"), "version").step);

    const install_path = b.getInstallPath(.prefix, ".");

    for (zbh.Ci.standard) |target_str| {
        const target = zbh.Ci.resolve(b, target_str);
        const platform = zbh.Platform.detect(target.result);
        const upstream = b.dependency("upstream", .{});

        // CI builds never use macOS SDK (cross-compilation doesn't have SDK headers)
        const lib_build = buildLibrary(b, target, .ReleaseFast, upstream, .static, false, true, null);

        const archive_root = b.fmt("c-ares-{s}-{s}", .{ version, target_str });
        const target_lib_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/lib", .{archive_root}) };
        const target_include_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/include", .{archive_root}) };
        const target_bin_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/bin", .{archive_root}) };

        const install_lib = b.addInstallArtifact(lib_build.lib, .{ .dest_dir = .{ .override = target_lib_dir } });
        const install_header = b.addInstallFileWithDir(upstream.path("include/ares.h"), target_include_dir, "ares.h");
        const install_header2 = b.addInstallFileWithDir(upstream.path("include/ares_dns.h"), target_include_dir, "ares_dns.h");
        const install_header3 = b.addInstallFileWithDir(upstream.path("include/ares_dns_record.h"), target_include_dir, "ares_dns_record.h");
        const install_header4 = b.addInstallFileWithDir(upstream.path("include/ares_nameser.h"), target_include_dir, "ares_nameser.h");
        const install_header5 = b.addInstallFileWithDir(upstream.path("include/ares_version.h"), target_include_dir, "ares_version.h");

        const tool_flags = &[_][]const u8{ "-std=gnu90", "-D_GNU_SOURCE", "-DHAVE_CONFIG_H", "-DCARES_NO_DEPRECATED" };
        const helper_sources = &[_][]const u8{"ares_getopt.c"};

        const ahost = b.addExecutable(.{
            .name = "ahost",
            .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
        });
        ahost.addIncludePath(upstream.path("src/tools"));
        ahost.addIncludePath(upstream.path("src/lib"));
        ahost.addIncludePath(upstream.path("src/lib/include"));
        ahost.addIncludePath(upstream.path("include"));
        ahost.addIncludePath(lib_build.ares_build_h.dirname());
        ahost.addConfigHeader(lib_build.config_h);
        if (platform.is_windows) {
            ahost.root_module.addCMacro("CARES_STATICLIB", "1");
        }
        ahost.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = &.{"ahost.c"}, .flags = tool_flags });
        ahost.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = helper_sources, .flags = tool_flags });
        ahost.linkLibrary(lib_build.lib);
        const install_ahost = b.addInstallArtifact(ahost, .{ .dest_dir = .{ .override = target_bin_dir } });

        const adig = b.addExecutable(.{
            .name = "adig",
            .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
        });
        adig.addIncludePath(upstream.path("src/tools"));
        adig.addIncludePath(upstream.path("src/lib"));
        adig.addIncludePath(upstream.path("src/lib/include"));
        adig.addIncludePath(upstream.path("include"));
        adig.addIncludePath(lib_build.ares_build_h.dirname());
        adig.addConfigHeader(lib_build.config_h);
        if (platform.is_windows) {
            adig.root_module.addCMacro("CARES_STATICLIB", "1");
        }
        adig.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = &.{"adig.c"}, .flags = tool_flags });
        adig.addCSourceFiles(.{ .root = upstream.path("src/tools"), .files = helper_sources, .flags = tool_flags });
        adig.linkLibrary(lib_build.lib);
        const install_adig = b.addInstallArtifact(adig, .{ .dest_dir = .{ .override = target_bin_dir } });

        const archive = zbh.Archive.create(b, archive_root, platform.is_windows, install_path);
        archive.step.dependOn(&install_lib.step);
        archive.step.dependOn(&install_header.step);
        archive.step.dependOn(&install_header2.step);
        archive.step.dependOn(&install_header3.step);
        archive.step.dependOn(&install_header4.step);
        archive.step.dependOn(&install_header5.step);
        archive.step.dependOn(&install_ahost.step);
        archive.step.dependOn(&install_adig.step);
        ci_step.dependOn(&archive.step);
    }
}

const sources = [_][]const u8{
    "ares_addrinfo2hostent.c",
    "ares_addrinfo_localhost.c",
    "ares_android.c",
    "ares_cancel.c",
    "ares_close_sockets.c",
    "ares_conn.c",
    "ares_cookie.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_hosts_file.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_metrics.c",
    "ares_options.c",
    "ares_parse_into_addrinfo.c",
    "ares_process.c",
    "ares_qcache.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_set_socket_functions.c",
    "ares_socket.c",
    "ares_sortaddrinfo.c",
    "ares_strerror.c",
    "ares_sysconfig.c",
    "ares_sysconfig_files.c",
    "ares_sysconfig_mac.c",
    "ares_sysconfig_win.c",
    "ares_timeout.c",
    "ares_update_servers.c",
    "ares_version.c",
    "inet_net_pton.c",
    "inet_ntop.c",
    "windows_port.c",
    "dsa/ares_array.c",
    "dsa/ares_htable.c",
    "dsa/ares_htable_asvp.c",
    "dsa/ares_htable_dict.c",
    "dsa/ares_htable_strvp.c",
    "dsa/ares_htable_szvp.c",
    "dsa/ares_htable_vpstr.c",
    "dsa/ares_htable_vpvp.c",
    "dsa/ares_llist.c",
    "dsa/ares_slist.c",
    "event/ares_event_configchg.c",
    "event/ares_event_epoll.c",
    "event/ares_event_kqueue.c",
    "event/ares_event_poll.c",
    "event/ares_event_select.c",
    "event/ares_event_thread.c",
    "event/ares_event_wake_pipe.c",
    "event/ares_event_win32.c",
    "legacy/ares_create_query.c",
    "legacy/ares_expand_name.c",
    "legacy/ares_expand_string.c",
    "legacy/ares_fds.c",
    "legacy/ares_getsock.c",
    "legacy/ares_parse_a_reply.c",
    "legacy/ares_parse_aaaa_reply.c",
    "legacy/ares_parse_caa_reply.c",
    "legacy/ares_parse_mx_reply.c",
    "legacy/ares_parse_naptr_reply.c",
    "legacy/ares_parse_ns_reply.c",
    "legacy/ares_parse_ptr_reply.c",
    "legacy/ares_parse_soa_reply.c",
    "legacy/ares_parse_srv_reply.c",
    "legacy/ares_parse_txt_reply.c",
    "legacy/ares_parse_uri_reply.c",
    "record/ares_dns_mapping.c",
    "record/ares_dns_multistring.c",
    "record/ares_dns_name.c",
    "record/ares_dns_parse.c",
    "record/ares_dns_record.c",
    "record/ares_dns_write.c",
    "str/ares_buf.c",
    "str/ares_str.c",
    "str/ares_strsplit.c",
    "util/ares_iface_ips.c",
    "util/ares_threads.c",
    "util/ares_timeval.c",
    "util/ares_math.c",
    "util/ares_rand.c",
    "util/ares_uri.c",
};

// Same as sources but without files that need macOS SDK headers:
// - ares_sysconfig_mac.c (needs SystemConfiguration/SCNetworkConfiguration.h)
// - event/ares_event_configchg.c (needs notify.h on macOS)
const sources_no_macos = [_][]const u8{
    "ares_addrinfo2hostent.c",
    "ares_addrinfo_localhost.c",
    "ares_android.c",
    "ares_cancel.c",
    "ares_close_sockets.c",
    "ares_conn.c",
    "ares_cookie.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_hosts_file.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_metrics.c",
    "ares_options.c",
    "ares_parse_into_addrinfo.c",
    "ares_process.c",
    "ares_qcache.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_set_socket_functions.c",
    "ares_socket.c",
    "ares_sortaddrinfo.c",
    "ares_strerror.c",
    "ares_sysconfig.c",
    "ares_sysconfig_files.c",
    // "ares_sysconfig_mac.c", // needs SystemConfiguration/SCNetworkConfiguration.h
    "ares_sysconfig_win.c",
    "ares_timeout.c",
    "ares_update_servers.c",
    "ares_version.c",
    "inet_net_pton.c",
    "inet_ntop.c",
    "windows_port.c",
    "dsa/ares_array.c",
    "dsa/ares_htable.c",
    "dsa/ares_htable_asvp.c",
    "dsa/ares_htable_dict.c",
    "dsa/ares_htable_strvp.c",
    "dsa/ares_htable_szvp.c",
    "dsa/ares_htable_vpstr.c",
    "dsa/ares_htable_vpvp.c",
    "dsa/ares_llist.c",
    "dsa/ares_slist.c",
    // "event/ares_event_configchg.c", // needs notify.h on macOS
    "event/ares_event_epoll.c",
    "event/ares_event_kqueue.c",
    "event/ares_event_poll.c",
    "event/ares_event_select.c",
    "event/ares_event_thread.c",
    "event/ares_event_wake_pipe.c",
    "event/ares_event_win32.c",
    "legacy/ares_create_query.c",
    "legacy/ares_expand_name.c",
    "legacy/ares_expand_string.c",
    "legacy/ares_fds.c",
    "legacy/ares_getsock.c",
    "legacy/ares_parse_a_reply.c",
    "legacy/ares_parse_aaaa_reply.c",
    "legacy/ares_parse_caa_reply.c",
    "legacy/ares_parse_mx_reply.c",
    "legacy/ares_parse_naptr_reply.c",
    "legacy/ares_parse_ns_reply.c",
    "legacy/ares_parse_ptr_reply.c",
    "legacy/ares_parse_soa_reply.c",
    "legacy/ares_parse_srv_reply.c",
    "legacy/ares_parse_txt_reply.c",
    "legacy/ares_parse_uri_reply.c",
    "record/ares_dns_mapping.c",
    "record/ares_dns_multistring.c",
    "record/ares_dns_name.c",
    "record/ares_dns_parse.c",
    "record/ares_dns_record.c",
    "record/ares_dns_write.c",
    "str/ares_buf.c",
    "str/ares_str.c",
    "str/ares_strsplit.c",
    "util/ares_iface_ips.c",
    "util/ares_threads.c",
    "util/ares_timeval.c",
    "util/ares_math.c",
    "util/ares_rand.c",
    "util/ares_uri.c",
};

const sources_no_threads = [_][]const u8{
    "ares_addrinfo2hostent.c",
    "ares_addrinfo_localhost.c",
    "ares_android.c",
    "ares_cancel.c",
    "ares_close_sockets.c",
    "ares_conn.c",
    "ares_cookie.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_hosts_file.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_metrics.c",
    "ares_options.c",
    "ares_parse_into_addrinfo.c",
    "ares_process.c",
    "ares_qcache.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_set_socket_functions.c",
    "ares_socket.c",
    "ares_sortaddrinfo.c",
    "ares_strerror.c",
    "ares_sysconfig.c",
    "ares_sysconfig_files.c",
    "ares_sysconfig_mac.c",
    "ares_sysconfig_win.c",
    "ares_timeout.c",
    "ares_update_servers.c",
    "ares_version.c",
    "inet_net_pton.c",
    "inet_ntop.c",
    "windows_port.c",
    "dsa/ares_array.c",
    "dsa/ares_htable.c",
    "dsa/ares_htable_asvp.c",
    "dsa/ares_htable_dict.c",
    "dsa/ares_htable_strvp.c",
    "dsa/ares_htable_szvp.c",
    "dsa/ares_htable_vpstr.c",
    "dsa/ares_htable_vpvp.c",
    "dsa/ares_llist.c",
    "dsa/ares_slist.c",
    // "event/ares_event_configchg.c", // requires event-thread path
    "event/ares_event_epoll.c",
    "event/ares_event_kqueue.c",
    "event/ares_event_poll.c",
    "event/ares_event_select.c",
    "event/ares_event_wake_pipe.c",
    "event/ares_event_win32.c",
    "legacy/ares_create_query.c",
    "legacy/ares_expand_name.c",
    "legacy/ares_expand_string.c",
    "legacy/ares_fds.c",
    "legacy/ares_getsock.c",
    "legacy/ares_parse_a_reply.c",
    "legacy/ares_parse_aaaa_reply.c",
    "legacy/ares_parse_caa_reply.c",
    "legacy/ares_parse_mx_reply.c",
    "legacy/ares_parse_naptr_reply.c",
    "legacy/ares_parse_ns_reply.c",
    "legacy/ares_parse_ptr_reply.c",
    "legacy/ares_parse_soa_reply.c",
    "legacy/ares_parse_srv_reply.c",
    "legacy/ares_parse_txt_reply.c",
    "legacy/ares_parse_uri_reply.c",
    "record/ares_dns_mapping.c",
    "record/ares_dns_multistring.c",
    "record/ares_dns_name.c",
    "record/ares_dns_parse.c",
    "record/ares_dns_record.c",
    "record/ares_dns_write.c",
    "str/ares_buf.c",
    "str/ares_str.c",
    "str/ares_strsplit.c",
    "util/ares_iface_ips.c",
    // "util/ares_threads.c", // threads disabled
    "util/ares_timeval.c",
    "util/ares_math.c",
    "util/ares_rand.c",
    "util/ares_uri.c",
};

const sources_no_macos_no_threads = [_][]const u8{
    "ares_addrinfo2hostent.c",
    "ares_addrinfo_localhost.c",
    "ares_android.c",
    "ares_cancel.c",
    "ares_close_sockets.c",
    "ares_conn.c",
    "ares_cookie.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_hosts_file.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_metrics.c",
    "ares_options.c",
    "ares_parse_into_addrinfo.c",
    "ares_process.c",
    "ares_qcache.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_set_socket_functions.c",
    "ares_socket.c",
    "ares_sortaddrinfo.c",
    "ares_strerror.c",
    "ares_sysconfig.c",
    "ares_sysconfig_files.c",
    // "ares_sysconfig_mac.c", // needs SystemConfiguration/SCNetworkConfiguration.h
    "ares_sysconfig_win.c",
    "ares_timeout.c",
    "ares_update_servers.c",
    "ares_version.c",
    "inet_net_pton.c",
    "inet_ntop.c",
    "windows_port.c",
    "dsa/ares_array.c",
    "dsa/ares_htable.c",
    "dsa/ares_htable_asvp.c",
    "dsa/ares_htable_dict.c",
    "dsa/ares_htable_strvp.c",
    "dsa/ares_htable_szvp.c",
    "dsa/ares_htable_vpstr.c",
    "dsa/ares_htable_vpvp.c",
    "dsa/ares_llist.c",
    "dsa/ares_slist.c",
    // "event/ares_event_configchg.c", // requires event-thread path
    "event/ares_event_epoll.c",
    "event/ares_event_kqueue.c",
    "event/ares_event_poll.c",
    "event/ares_event_select.c",
    "event/ares_event_wake_pipe.c",
    "event/ares_event_win32.c",
    "legacy/ares_create_query.c",
    "legacy/ares_expand_name.c",
    "legacy/ares_expand_string.c",
    "legacy/ares_fds.c",
    "legacy/ares_getsock.c",
    "legacy/ares_parse_a_reply.c",
    "legacy/ares_parse_aaaa_reply.c",
    "legacy/ares_parse_caa_reply.c",
    "legacy/ares_parse_mx_reply.c",
    "legacy/ares_parse_naptr_reply.c",
    "legacy/ares_parse_ns_reply.c",
    "legacy/ares_parse_ptr_reply.c",
    "legacy/ares_parse_soa_reply.c",
    "legacy/ares_parse_srv_reply.c",
    "legacy/ares_parse_txt_reply.c",
    "legacy/ares_parse_uri_reply.c",
    "record/ares_dns_mapping.c",
    "record/ares_dns_multistring.c",
    "record/ares_dns_name.c",
    "record/ares_dns_parse.c",
    "record/ares_dns_record.c",
    "record/ares_dns_write.c",
    "str/ares_buf.c",
    "str/ares_str.c",
    "str/ares_strsplit.c",
    "util/ares_iface_ips.c",
    // "util/ares_threads.c", // threads disabled
    "util/ares_timeval.c",
    "util/ares_math.c",
    "util/ares_rand.c",
    "util/ares_uri.c",
};
