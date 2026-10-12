"""Export the shared JSON protocol cases for C and Bash tests."""
import argparse
import json
from pathlib import Path


def c_string(value):
    return json.dumps(value, ensure_ascii=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('format', choices=('c', 'bash'))
    args = parser.parse_args()
    data = json.loads((Path(__file__).parent / 'fixtures/frames.json').read_text())
    if args.format == 'bash':
        for f in data['frames']:
            print('\t'.join(map(str, ('frame', f['name'], f['hex'], f['report_id'],
                                    f['device_index'], f['feature_index'], f['function'],
                                    ' '.join(map(str, f['params'])) or '-'))))
        for r in data['replies']:
            print('\t'.join(map(str, ('reply', r['name'], r['outcome'], r['hex'],
                                    r['device_index'], r['feature_index'], r.get('function', 0), '-'))))
        return
    print('struct fixture_frame { const char *name; unsigned rid, didx, fidx, function; '
          'unsigned char params[16]; unsigned count; const char *hex; };')
    print('static const struct fixture_frame fixture_frames[] = {')
    for f in data['frames']:
        params = ','.join(map(str, f['params'])) or '0'
        print('{' + ','.join((c_string(f['name']), str(f['report_id']), str(f['device_index']),
                             str(f['feature_index']), str(f['function']), '{' + params + '}',
                             str(len(f['params'])), c_string(f['hex']))) + '},')
    print('};')
    print('struct fixture_reply { const char *name, *hex; unsigned didx, fidx, function; const char *outcome; };')
    print('static const struct fixture_reply fixture_replies[] = {')
    for r in data['replies']:
        print('{' + ','.join((c_string(r['name']), c_string(r['hex']), str(r['device_index']),
                             str(r['feature_index']), str(r.get('function', 0)), c_string(r['outcome']))) + '},')
    print('};')


if __name__ == '__main__':
    main()
