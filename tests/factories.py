from pathlib import Path

from upscayl_video.probe import MediaInfo, StreamInfo


def make_media_info(
    source: Path,
    *,
    duration: float = 5.0,
    fps_num: int = 30,
    fps_den: int = 1,
    width: int = 320,
    height: int = 240,
    pix_fmt: str = "yuv420p",
    audio: tuple[StreamInfo, ...] = (),
    subtitles: tuple[StreamInfo, ...] = (),
    chapters: int = 0,
    color_trc: str | None = "bt709",
    color_range: str | None = "tv",
    color_primaries: str | None = "bt709",
    colorspace: str | None = "bt709",
    hdr: bool = False,
    rotation: int = 0,
) -> MediaInfo:
    exists = source.exists()
    return MediaInfo(
        source=source,
        duration=duration,
        fps_num=fps_num,
        fps_den=fps_den,
        width=width,
        height=height,
        pix_fmt=pix_fmt,
        video_index=0,
        audio=audio,
        subtitles=subtitles,
        chapters=chapters,
        color_primaries=color_primaries,
        color_trc=color_trc,
        colorspace=colorspace,
        color_range=color_range,
        rotation=rotation,
        hdr=hdr,
        source_size=source.stat().st_size if exists else 0,
        source_mtime=int(source.stat().st_mtime) if exists else 0,
    )
