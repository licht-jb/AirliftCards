# Airlift Cards

`Airlift Cards` is a macOS interface for changing Apple Pay card artwork on a
paired iPhone. It lists connected devices and copies only payment-card metadata,
artwork, and generated thumbnails. Boarding passes, tickets, and other passes
are excluded.

The first artwork seen before replacement is saved under
`~/Library/Application Support/Airlift Cards/Backups`. The restore action uses
that saved original. Images and the first page of PDFs are center-cropped to the
selected card's native artwork size.

The `Backend` directory contains copies of the shared Airlift implementation and
native helper sources so this project builds independently from the original
repository.

## Build

XcodeGen, Xcode 27, and Pillow for `/usr/bin/python3` are required.

```sh
make app
open "build/Airlift Cards.app"
```

## Acknowledgements

Airlift Cards is built on [airlift](https://github.com/0xjohnnydev/airlift),
the AirTraffic/ATAirlock research and implementation by
[Johnny Franks (@0xjohnnydev)](https://github.com/0xjohnnydev). Airlift provides
the paired-Mac file access and native helper foundation used by this app.
Airlift Cards adds the macOS interface and the card-artwork workflow on top of
that work. Many thanks to Johnny Franks for publishing the original research
and code.

## License

Airlift Cards is available under the [MIT License](LICENSE). The copied Airlift
components remain copyright © 2026 Johnny Franks and are used under the
[original project's MIT License](https://github.com/0xjohnnydev/airlift/blob/main/LICENSE).
