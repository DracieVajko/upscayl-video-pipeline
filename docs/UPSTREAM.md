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
> V1 is a Python CLI; a no-Python PowerShell/bash V2 is planned in the same
> repository. It keeps each video in its own work folder, accepts Upscayl's
> suffixed batch output, handles audio/subtitles and MP4/MKV/ProRes, and
> documents a Windows/NVIDIA Vulkan ICD workaround for the
> `vkEnumeratePhysicalDevices failed 5` error. Not affiliated with Upscayl.
>
> Feedback is welcome, especially from users on AMD-only machines.

Posting this comment is a public side effect. Do it only after the owner of the
repository approves the final wording.
