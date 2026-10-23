#!/usr/bin/env python3
"""Re-apply terminal reset patch to Happy after 'happy update'."""
import glob, os, sys

candidates = (
    glob.glob(os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.cjs"))
    + glob.glob(os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.mjs"))
)
candidates = [
    f for f in candidates
    if not (f.endswith("index.cjs") or f.endswith("index.mjs") or ".bak" in f)
]

if not candidates:
    print("ERROR: no happy dist file found")
    sys.exit(1)

old = '''          case "switch":
            mode = "local";
            opts.onModeChange?.(mode);
            break;
        }
        break;
      }
    }
  }
}'''

new = '''          case "switch":
            mode = "local";
            opts.onModeChange?.(mode);
            process.stdout.write("\\x1bc");
            break;
        }
        break;
      }
    }
  }
}'''

for path in candidates:
    with open(path) as f:
        content = f.read()

    if 'process.stdout.write("\\x1bc")' in content:
        print(f"SKIP (already patched): {path}")
        continue

    if old not in content:
        print(f"SKIP (pattern not in file): {path}")
        continue

    with open(path, 'w') as f:
        f.write(content.replace(old, new))
    print(f"PATCHED: {path}")
