#!/usr/bin/env python3
"""Configure this checkout only; this entry point does not deploy anything."""

import argparse
from pathlib import Path
import sys

from deploy_config import ConfigCancelled, ConfigError, choose_config


def main():
    parser = argparse.ArgumentParser(description="创建或选择本机私有部署配置。")
    parser.add_argument("--reuse-existing", action="store_true",
                        help="非交互调用时明确允许复用已有的有效配置")
    args = parser.parse_args()
    try:
        choose_config(repository=Path(__file__).resolve().parents[1],
                      reuse_existing=args.reuse_existing)
    except ConfigCancelled:
        print("已取消配置，未开始部署。")
        return 0
    except ConfigError as error:
        print("配置已停止：" + str(error), file=sys.stderr)
        return 65
    print("私有配置已就绪，尚未开始部署。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
