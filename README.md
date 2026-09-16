# Airlift Cards

A macOS app for replacing and restoring Apple Pay card artwork on a paired
iPhone using images or PDFs.

## Install

Download the DMG from the [latest release](https://github.com/licht-jb/AirliftCards/releases/latest)
and drag `Airlift Cards` to the Applications folder.

## Build

Building requires macOS 27, Xcode 27, XcodeGen, and Pillow for
`/usr/bin/python3`.

```sh
make app
open "build/Airlift Cards.app"
```

## Runtime requirements

- macOS 14 or later on Apple silicon
- A paired iPhone on a supported iOS build

## License and credits

Airlift Cards is available under the [MIT License](LICENSE). It builds on
[airlift](https://github.com/0xjohnnydev/airlift) by
[Johnny Franks (@0xjohnnydev)](https://github.com/0xjohnnydev), also released
under [MIT](https://github.com/0xjohnnydev/airlift/blob/main/LICENSE); thanks to
Johnny Franks for making the work public.
