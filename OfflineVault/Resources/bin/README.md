# Bundled helper binaries

This folder is populated by `scripts/fetch_binaries.sh` and is git-ignored apart from this file.
Expected layout after running the script:

    bin/
      kiwix-serve                 (kiwix-tools 3.8.2; arm64 static build from scripts/build_kiwix_serve.sh, or the
                                   x86_64 download under Rosetta 2 with --allow-rosetta, see README)
      yt-dlp                      (yt-dlp 2026.08.19, universal macOS binary)
      ffmpeg                      (FFmpeg 9.0.2, macOS arm64 static build)
      llama/
        llama-server              (llama.cpp b11552, macOS arm64)
        *.dylib                   (libllama, libggml*, libmtmd … required next to llama-server)
      VERSIONS.txt                (what was fetched, with checksums)
