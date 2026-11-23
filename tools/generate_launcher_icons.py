from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "free_scanner_icon.png"
FOREGROUND = ROOT / "assets" / "free_scanner_icon_foreground.png"
SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def main() -> None:
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    master = Image.open(SOURCE).convert("RGBA")
    foreground = Image.open(FOREGROUND).convert("RGBA")
    for folder, size in SIZES.items():
        destination = ROOT / "android" / "app" / "src" / "main" / "res" / folder / "ic_launcher.png"
        destination.parent.mkdir(parents=True, exist_ok=True)
        master.resize((size, size), Image.Resampling.LANCZOS).save(destination, optimize=True)
    foreground_destination = ROOT / "android" / "app" / "src" / "main" / "res" / "drawable-nodpi" / "ic_launcher_foreground.png"
    foreground_destination.parent.mkdir(parents=True, exist_ok=True)
    foreground.save(foreground_destination, optimize=True)
    print(f"Generated launcher icon assets under {SOURCE.parent}")


if __name__ == "__main__":
    main()
