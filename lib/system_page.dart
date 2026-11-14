part of 'main.dart';

/// System page (swipe right from Wheels): runs phone_ctl.sh verbs on orintwo over ssh
/// (navigation_ws #27) and shows each step as it streams in. Left: the steps, long-press
/// one for its log. Right: Up, Stop, Camera on, Status, Recenter wheels…, Show public key.
class SystemPage extends StatelessWidget {
  const SystemPage({super.key, required this.ctl, this.onWheels, this.onEditHost});

  final SystemController ctl;
  final VoidCallback? onWheels;
  final VoidCallback? onEditHost;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(height: 40, child: _header()),
              const SizedBox(height: 4),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 5, child: _steps(context)),
                  const SizedBox(width: 16),
                  Expanded(flex: 4, child: _buttons(context)),
                ]),
              ),
            ]),
          ),
        ),
      );

  (String, Color) get _sshText => switch (ctl.ssh) {
        SshState.idle => ('ssh idle', dim),
        SshState.connecting => ('ssh connecting…', warn),
        SshState.ok => ('ssh ok', ok),
        SshState.failed => ('ssh failed', bad),
        SshState.hostKeyChanged => ('HOST KEY CHANGED', bad),
      };

  Widget _header() {
    final (text, color) = _sshText;
    return Row(children: [
      const Text('SYSTEM', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
      const SizedBox(width: 16),
      Flexible(
        child: TextButton(
          onPressed: onEditHost,
          style: TextButton.styleFrom(foregroundColor: dim, padding: const EdgeInsets.symmetric(horizontal: 4)),
          child: Text(ctl.host ?? sshDefaultHost, overflow: TextOverflow.ellipsis),
        ),
      ),
      const SizedBox(width: 6),
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(color: color == dim ? dim : color, fontWeight: FontWeight.w600)),
      const Spacer(),
      if (onWheels != null) TextButton(onPressed: onWheels, child: const Text('Wheels ›')),
    ]);
  }

  Widget _steps(BuildContext context) {
    final changed = ctl.hostKeyChanged;
    final result = _resultText();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(color: panel, border: Border.all(color: line), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (changed != null) _HostKeyBanner(changed: changed, onTrust: () => _confirmTrust(context)),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            for (final r in ctl.rows.values) StepTile(row: r, current: r.run == ctl.runId, onLog: () => _showLog(context, r.step)),
          ]),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(result.$1,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: result.$2, fontSize: 13)),
          ),
        const Text('long-press a row → log', style: TextStyle(color: dim, fontSize: 11)),
      ]),
    );
  }

  (String, Color)? _resultText() {
    final v = ctl.lastVerb;
    if (v == null) return null;
    if (ctl.busy != null) return ('${ctl.busy} running…', dim);
    if (ctl.lastOk == true) return ('$v: ok', ok);
    if (ctl.lastOk == false) return ('$v: failed${ctl.lastError == null ? '' : ' — ${ctl.lastError}'}', bad);
    return ('$v: ${ctl.lastError ?? 'no result'}', bad);
  }

  Widget _buttons(BuildContext context) {
    final busy = ctl.busy;
    void Function()? verb(String v) => busy == null ? () => ctl.run(v) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: _NoPageSwipe(child: _big('UP', verb('up'), color: ok, running: busy == 'up'))),
      const SizedBox(height: 6),
      // always on: cancels whatever runs and tears down
      Expanded(child: _NoPageSwipe(child: _big('STOP', () => ctl.run('stop'), color: bad, running: busy == 'stop'))),
      const SizedBox(height: 6),
      _small('Camera on', verb('camera'), running: busy == 'camera'),
      const SizedBox(height: 6),
      _small('Status', verb('status'), running: busy == 'status'),
      const SizedBox(height: 10),
      _small('Recenter wheels…', busy == null ? () => _recenter(context) : null, running: busy?.startsWith('zero') == true),
      const SizedBox(height: 6),
      _small('Show public key', () => _showKey(context)),
    ]);
  }

  static Widget _big(String label, VoidCallback? onPressed, {required Color color, bool running = false}) =>
      OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: color == bad ? const Color(0xFF7F1D1D) : panel,
          side: BorderSide(color: onPressed == null ? line : color, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          foregroundColor: Colors.white,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(running ? '$label …' : label,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 3)),
      );

  static Widget _small(String label, VoidCallback? onPressed, {bool running = false}) => _NoPageSwipe(
        child: SizedBox(
          height: 36,
          child: OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              backgroundColor: panel,
              side: BorderSide(color: running ? accent : line, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              foregroundColor: Colors.white,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(running ? '$label …' : label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      );

  Future<void> _confirmTrust(BuildContext context) async {
    final c = ctl.hostKeyChanged!;
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Trust the new host key?'),
        content: Text('Only if orintwo was reinstalled or its ssh keys regenerated. Check on orintwo:\n'
            'ssh-keygen -l -E md5 -f /etc/ssh/ssh_host_ed25519_key.pub\n\nnew: ${c.offered}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: bad),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Trust new key'),
          ),
        ],
      ),
    );
    if (yes == true) await ctl.trustNewHostKey();
  }

  Future<void> _showLog(BuildContext context, String step) async {
    final lines = ctl.log(step);
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('log $step'),
        content: SizedBox(
          width: 640,
          child: FutureBuilder<List<String>>(
            future: lines,
            builder: (context, snap) => snap.hasData
                ? SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(snap.data!.isEmpty ? '(empty)' : snap.data!.join('\n'),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  )
                : const Text('loading…', style: TextStyle(color: dim)),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _showKey(BuildContext context) async {
    final key = ctl.ctl.publicKey();
    final pinned = ctl.ctl.pinnedHostKey();
    await showDialog<void>(
      context: context,
      builder: (d) => FutureBuilder<List<String?>>(
        future: Future.wait([key, pinned]),
        builder: (context, snap) {
          final k = snap.data?[0];
          return AlertDialog(
            title: const Text('Phone public key'),
            content: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (snap.hasError) Text('${snap.error}', style: const TextStyle(color: bad)),
                  SelectableText(k ?? 'generating…', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text('Install it on orintwo with scripts/robot_setup/phone_link.sh (it may only run phone_ctl.sh).',
                      style: TextStyle(color: dim, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text('orintwo host key: ${snap.data?[1] ?? 'not pinned yet (trusted on first connect)'}',
                      style: const TextStyle(color: dim, fontSize: 12)),
                ]),
              ),
            ),
            actions: [
              TextButton(
                onPressed: k == null ? null : () => Clipboard.setData(ClipboardData(text: k)),
                child: const Text('Copy'),
              ),
              TextButton(
                onPressed: k == null ? null : () => Share.share(k, subject: 'rover_teleop phone key'),
                child: const Text('Share'),
              ),
              FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Close')),
            ],
          );
        },
      ),
    );
  }

  Future<void> _recenter(BuildContext context) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RecenterDialog(ctl: ctl),
      );
}

class _HostKeyBanner extends StatelessWidget {
  const _HostKeyBanner({required this.changed, required this.onTrust});

  final HostKeyChanged changed;
  final VoidCallback onTrust;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF450A0A),
          border: Border.all(color: bad, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          const Icon(Icons.gpp_bad, color: bad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '⚠ ${changed.host} answered with a DIFFERENT HOST KEY. Not connecting: this may not be orintwo.\n'
              'pinned ${changed.pinned}\nnow    ${changed.offered}',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFFECACA), fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: onTrust, child: const Text('Trust…', style: TextStyle(color: bad))),
        ]),
      );
}

/// One step: ✓ ok, ✗ fail (reason in red below), ⟳ running (reason inline, e.g. "retry 1/3"),
/// ! warn, – skipped, · not run. Rows from an earlier run are dimmed.
class StepTile extends StatelessWidget {
  const StepTile({super.key, required this.row, required this.current, this.onLog});

  final StepRow row;
  final bool current;
  final VoidCallback? onLog;

  static const _icons = {'ok': '✓', 'fail': '✗', 'running': '⟳', 'warn': '!', 'skipped': '–'};
  static const _colors = {'ok': ok, 'fail': bad, 'running': accent, 'warn': warn, 'skipped': dim};

  @override
  Widget build(BuildContext context) {
    final r = row;
    final color = _colors[r.state] ?? dim;
    final inline = r.state == 'running' || r.state == 'skipped' || (r.state == 'idle' && r.step == 'camera');
    final note = r.state == 'idle' && r.step == 'camera' ? 'separate' : r.reason;
    final below = (r.state == 'fail' || r.state == 'warn') && r.reason.isNotEmpty;
    return InkWell(
      onLongPress: onLog,
      child: Opacity(
        opacity: current || r.state == 'idle' ? 1 : .45,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              SizedBox(
                width: 20,
                child: Text(_icons[r.state] ?? '·',
                    style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              Text(r.step, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (inline && note.isNotEmpty)
                Expanded(
                  child: Text('($note)',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim, fontSize: 13)),
                )
              else
                const Spacer(),
              if (r.t != null && r.state != 'running')
                Text('${r.t!.toStringAsFixed(1)} s',
                    style: const TextStyle(color: dim, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            if (below)
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Text(r.reason,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 13)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Recenter wheels: explains, then 4 tick boxes (none ticked), a confirm naming the ticked
/// ids → `zero <ids>`, then the streamed steps.
class RecenterDialog extends StatefulWidget {
  const RecenterDialog({super.key, required this.ctl});

  final SystemController ctl;

  @override
  State<RecenterDialog> createState() => _RecenterDialogState();
}

class _RecenterDialogState extends State<RecenterDialog> {
  final ticked = <int>{};
  int? startedRun; // runId of our `zero`, once sent

  List<int> get _ids => wheelIds.values.where(ticked.contains).toList();

  void _start() {
    widget.ctl.run('zero ${_ids.join(' ')}');
    setState(() => startedRun = widget.ctl.runId);
  }

  @override
  Widget build(BuildContext context) {
    final names = {for (final e in wheelIds.entries) e.value: e.key};
    final label = _ids.map((id) => '${names[id]} $id').join(', ');
    if (startedRun == null) {
      return AlertDialog(
        title: const Text('Recenter wheels'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('The wheels go limp while their zero is set: align the ticked wheels straight by hand, '
                  'then confirm. The wheels controller restarts afterwards.'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final e in wheelIds.entries)
                  SizedBox(
                    width: 120,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('${e.key} ${e.value}'),
                      value: ticked.contains(e.value),
                      onChanged: (v) => setState(() => v == true ? ticked.add(e.value) : ticked.remove(e.value)),
                    ),
                  ),
              ]),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: ticked.isEmpty || widget.ctl.busy != null ? null : _start,
            child: Text(ticked.isEmpty ? 'Tick a wheel' : 'Zero $label'),
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: widget.ctl,
      builder: (context, _) {
        final c = widget.ctl;
        final mine = c.runId == startedRun;
        final running = mine && c.busy != null;
        final rows = c.rows.values.where((r) => r.run == startedRun).toList();
        final String status;
        final Color color;
        if (running) {
          (status, color) = ('running…', dim);
        } else if (mine && c.lastOk == true) {
          (status, color) = ('done: ok', ok);
        } else {
          (status, color) = (mine ? 'failed${c.lastError == null ? '' : ' — ${c.lastError}'}' : 'interrupted', bad);
        }
        return AlertDialog(
          title: Text('zero ${_ids.join(' ')}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final r in rows) StepTile(row: r, current: true),
                const SizedBox(height: 6),
                Text(status, style: TextStyle(color: color)),
              ]),
            ),
          ),
          actions: [
            if (running)
              TextButton(
                onPressed: () => c.run('stop'),
                child: const Text('STOP', style: TextStyle(color: bad, fontWeight: FontWeight.w800)),
              ),
            FilledButton(onPressed: running ? null : () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
    );
  }
}
