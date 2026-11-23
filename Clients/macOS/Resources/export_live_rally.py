"""Export one persisted RallyCapture match to flat analysis tables."""
import argparse
import csv
import json
from contextlib import ExitStack
from pathlib import Path
from tempfile import TemporaryDirectory


def export(folder, output):
    paths = sorted((folder / 'batches').glob('*.json'))
    if not paths or output.exists():
        raise ValueError('请选择包含 batches 的比赛目录和一个新的输出目录')
    counts = {}
    gaps = []
    expected = 0
    imu_fields = 'rx ry rz ax_g ay_g az_g gx gy gz qx qy qz qw'.split()
    with TemporaryDirectory(dir=output.parent) as tmp:
        stage = Path(tmp) / 'export'
        stage.mkdir()
        with ExitStack() as stack:
            def table(name, fields):
                file = stack.enter_context((stage / (name + '.csv')).open('w', newline='', encoding='utf-8-sig'))
                writer = csv.DictWriter(file, fieldnames=['batch', *fields])
                writer.writeheader()
                counts[name] = 0

                def append(seq, row):
                    writer.writerow(dict(batch=seq, **row))
                    counts[name] += 1
                return append

            imu = table('motion', ['t_phone', *imu_fields, 'armed', 'tracking', 'trigger', 'gripSimilarity'])
            event = table('events', 'time kind text aim peakTime recognizedAt gameTime judgedAt accepted candidateGame curve curveScore curveMargin'.split())
            tick = table('ticks', 'time gameTime delta playerX playerY opponentX opponentY ball'.split())
            state = table('states', 'phoneTime gameTime phase score playerX playerY opponentX opponentY flight hitWindowOpen displayOffset message input mode difficulty leftHand lightSwing curveVersion'.split())
            trials = {}
            scenes = {}
            for path in paths:
                batch = json.loads(path.read_text())
                seq = batch['sequence']
                if batch['match'].lower() != folder.name.lower() or seq != int(path.stem):
                    raise ValueError(f'比赛或序号不一致 {path}')
                if seq > expected:
                    gaps.append([expected, seq - 1])
                expected = seq + 1
                snapshot = dict(batch['state'])
                mode = snapshot.get('mode', '').split('/')
                trial = None
                if len(mode) == 3 and mode[0] == '单球复测':
                    trial = trials.setdefault(mode[2], dict(number=mode[2], target=mode[1],
                        input=snapshot.get('input'), first_phone_time=batch['phoneTime'],
                        last_phone_time=batch['phoneTime'], candidates=0, judgments=[], direction=[],
                        outcome='未完成', trajectory=''))
                    trial['last_phone_time'] = batch['phoneTime']
                elif len(mode) == 5 and mode[0] == '场景采集':
                    _, scene, number, group, block_size = mode
                    trial = scenes.setdefault(number, dict(number=number, scene=scene, group=group,
                        block_size=block_size, input=snapshot.get('input'), first_phone_time=batch['phoneTime'],
                        last_phone_time=batch['phoneTime'], candidates=0, judgments=[], direction=[],
                        recognized_action=[], reviewed_action='', outcome='未完成', trajectory=''))
                    trial['last_phone_time'] = batch['phoneTime']
                for key in ['score', 'flight']:
                    snapshot[key] = json.dumps(snapshot.get(key), ensure_ascii=False)
                state(seq, dict(phoneTime=batch['phoneTime'], **snapshot))
                for frame in batch['frames']:
                    if len(frame['v']) != len(imu_fields):
                        raise ValueError('IMU 通道数异常')
                    flags = {k: frame.get(k) for k in ('armed', 'tracking', 'trigger', 'gripSimilarity')}
                    imu(seq, dict(t_phone=frame['t'], **dict(zip(imu_fields, frame['v'])), **flags))
                for item in batch.get('ticks', []):
                    tick(seq, item)
                for item in batch['events']:
                    event(seq, item)
                    if trial is None:
                        continue
                    kind = item['kind']
                    if kind == 'candidate':
                        trial['candidates'] += 1
                    elif kind == 'judgment':
                        trial['judgments'].append(item['text'])
                        trial['direction'].append(item.get('candidateGame', ''))
                    elif kind == 'impact' and 'recognized_action' in trial:
                        trial['recognized_action'].append(item['text'].split(' · ')[0])
                    elif kind == 'trajectory':
                        trial['trajectory'] = item['text']
                    elif kind == 'repeatTrial' and item['text'].endswith('/point'):
                        trial['outcome'] = snapshot['message']
                    elif kind == 'repeatTrial' and item['text'].endswith('/replayPoint') and trial['outcome'] == '未完成':
                        trial['outcome'] = '手动重试'
            for records, filename in [(trials, '单球复测.csv'), (scenes, '场景采集.csv')]:
                if not records:
                    continue
                with (stage / filename).open('w', newline='', encoding='utf-8-sig') as file:
                    writer = csv.DictWriter(file, fieldnames=list(next(iter(records.values()))))
                    writer.writeheader()
                    for row in records.values():
                        writer.writerow({k: ' | '.join(v) if isinstance(v, list) else v for k, v in row.items()})
        summary = dict(match=folder.name, batches=len(paths), rows=counts, missing_ranges=gaps)
        (stage / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        stage.rename(output)
        return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('match', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(export(args.match, args.output))
