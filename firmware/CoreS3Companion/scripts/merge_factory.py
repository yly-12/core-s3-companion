"""Build a single-file ESP32-S3 factory image after PlatformIO finishes."""

from pathlib import Path
import subprocess

Import("env")  # type: ignore[name-defined]  # Provided by PlatformIO/SCons.


def _flash_frequency(value: str) -> str:
    hz = int(value.rstrip("L"))
    return f"{hz // 1_000_000}m"


def merge_factory_image(source, target, env):
    del source, target

    platform = env.PioPlatform()
    board = env.BoardConfig()
    build_dir = Path(env.subst("$BUILD_DIR"))
    framework_dir = Path(platform.get_package_dir("framework-arduinoespressif32"))
    output = build_dir / f"{env.subst('$PROGNAME')}-factory.bin"

    command = [
        env.subst("$PYTHONEXE"),
        env.subst("$OBJCOPY"),
        "--chip",
        board.get("build.mcu", "esp32s3"),
        "merge_bin",
        "-o",
        str(output),
        "--flash_mode",
        board.get("build.flash_mode", "dio"),
        "--flash_freq",
        _flash_frequency(board.get("build.f_flash", "40000000L")),
        "--flash_size",
        board.get("upload.flash_size", "detect"),
        "0x0000",
        str(build_dir / "bootloader.bin"),
        "0x8000",
        str(build_dir / "partitions.bin"),
        "0xe000",
        str(framework_dir / "tools" / "partitions" / "boot_app0.bin"),
        env.subst("$ESP32_APP_OFFSET"),
        str(build_dir / f"{env.subst('$PROGNAME')}.bin"),
    ]

    print(f"Merging factory image: {output}")
    subprocess.run(command, check=True)


env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", merge_factory_image)
