#!/usr/bin/env python3
"""Restore binary assets (app icons, KaTeX fonts) from base64 manifests.

The repository stores binary files as base64 manifests under `scripts/`
(`binary-assets.NNN.b64`, one `path<TAB>base64` pair per line) so the repo
stays text-only and friendly to GitHub web viewing. Run this script once
after cloning, before building the HAP:

    python3 scripts/restore_binaries.py

Pure standard library; works with Python 3.6+ on any OS.
"""

import base64
import glob
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFESTS = sorted(glob.glob(os.path.join(REPO_ROOT, 'scripts', 'binary-assets.*.b64')))


def main() -> int:
    if not MANIFESTS:
        print('No binary-assets.*.b64 manifests found under scripts/.')
        return 1

    restored = 0
    for manifest in MANIFESTS:
        with open(manifest, 'r', encoding='ascii') as fh:
            for line in fh:
                line = line.rstrip('\n')
                if not line:
                    continue
                rel, b64 = line.split('\t', 1)
                target = os.path.join(REPO_ROOT, rel.replace('/', os.sep))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, 'wb') as out:
                    out.write(base64.b64decode(b64))
                restored += 1
        print(f'{os.path.basename(manifest)}: done')

    print(f'Restored {restored} binary files.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
