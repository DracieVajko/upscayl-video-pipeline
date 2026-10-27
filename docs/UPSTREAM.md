# Mentioning this project to Upscayl

This project is an **unofficial external add-on**. It does not modify Upscayl;
it orchestrates FFmpeg and Upscayl's own binary/GUI around a video workflow.
It is not affiliated with or endorsed by the Upscayl maintainers.

## Do not open a code PR

Upscayl's core is a C++/Electron application. A pull request that only adds a
separate Python or shell tool would be off-topic and would likely be closed.
Maintainers have previously said they do not want Python or external script
dependencies in the core repository.

## Recommended path

1. Publish this repository (done).
2. Add **one** concise comment to the pinned community guide:
   <https://github.com/orgs/upscayl/discussions/542>
3. If a maintainer asks for documentation, contribute a short guide to the
   wiki or docs — not a code PR.
4. Do not open issues solely to advertise the project, and do not post the same
   link in multiple threads.

## Draft comment

> I built an unofficial split → Upscayl GUI → assemble pipeline around the
> workflow in this guide:
> https://github.com/DracieVajko/upscayl-video-pipeline
>
> It is a separate folder/tool, not a fork and not affiliated with Upscayl.
> You put the original videos in the work folder; the script splits them into
> frames; you batch-upscale the frames in Upscayl's GUI; then the script
> assembles the frames back into a video with the original audio/subtitles.
> Upscayl itself is untouched.
>
> V1 (Python) and V2 (PowerShell for Windows, bash for Unix; no Python/Node/jq)
> cover split, manual GUI or automated `upscayl-bin` upscaling, all-in-one
> `run`, chunked processing, and assemble: PNG/JPEG frames, resume, MP4/MKV/
> ProRes, NVIDIA/AMD/CPU encoding, and a documented Windows Vulkan ICD
> workaround for `vkEnumeratePhysicalDevices failed 5` (an old AMD driver can
> break enumeration; forcing the NVIDIA ICD works). Both versions share the
> same `job.txt` contract.
>
> Feedback welcome, especially from AMD-only users. If this belongs in the
> wiki instead of a comment, I'm happy to turn it into a short docs entry.

Posting this comment is a public side effect. Do it only after the owner of the
repository approves the final wording.
