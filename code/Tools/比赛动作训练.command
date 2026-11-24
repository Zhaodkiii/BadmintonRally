#!/bin/zsh
set -eu
cd "${0:A:h}/.."
workspace="${1:-$PWD/../data/羽球比赛训练}"
.venv/bin/python Tools/train_match_reference.py "$workspace"
Tools/动作回放.command "$workspace/游戏复测"
lab="${TMPDIR:-/tmp}/RallyCourtMotionLab"
"$lab" --phases "$workspace/专项关节逐帧"
"$lab" --audit-arms "$workspace/专项关节左右手与帧率.csv"
