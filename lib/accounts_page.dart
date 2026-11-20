import 'package:gotohp_rs/error_messages.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:material_ui/material_ui.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsState();
}

class _AccountsState extends State<AccountsPage> {
  List<AccountInfo> _accounts = [];
  String _selected = '';
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final accounts = await listAccounts();
      final selected = await selectedAccount();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _selected = selected;
      });
    } catch (e) {
      _setError(e);
    }
  }

  void _setError(Object e) {
    if (mounted) setState(() => _error = friendlyError(e));
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    var raw = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Add Google account'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Raw credential')),
                    ButtonSegment(value: false, label: Text('oauth_token')),
                  ],
                  selected: {raw},
                  onSelectionChanged: (s) => setDialog(() => raw = s.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: raw
                        ? 'androidId=...&Email=...&Token=...'
                        : 'oauth_token cookie value',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || controller.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await getSettings();
      final email = raw
          ? await addAccountRaw(credential: controller.text.trim())
          : await addAccountOauth(
              oauthToken: controller.text.trim(),
              proxy: settings.proxy,
            );
      await selectAccount(email: email);
      await _load();
      if (mounted) setState(() => _notice = 'Connected $email');
    } catch (e) {
      _setError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test(AccountInfo account) async {
    try {
      await validateAccount(email: account.email);
      if (mounted) {
        setState(() => _notice = '${account.email}: credential accepted');
      }
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _remove(AccountInfo account) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text('Remove ${account.email} from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await removeAccount(email: account.email);
      await _load();
    } catch (e) {
      _setError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Accounts',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_accounts.length} Google account(s) stored on this device',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _add,
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('Add account'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: cs.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: SelectableText(
                      _error!,
                      style: TextStyle(color: cs.error, fontSize: 12),
                    ),
                  ),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _notice!,
                    style: TextStyle(color: Colors.green.shade700),
                  ),
                ),
              if (_accounts.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(48),
                    child: Column(
                      children: [
                        Icon(
                          Icons.account_circle_outlined,
                          size: 40,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No accounts yet',
                          style: TextStyle(fontSize: 15, color: cs.onSurface),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Add a credential to start uploading.',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                for (final account in _accounts)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.primary.withValues(alpha: 0.12),
                        child: Text(
                          account.email[0].toUpperCase(),
                          style: TextStyle(color: cs.primary),
                        ),
                      ),
                      title: Text(
                        account.email,
                        style: TextStyle(fontSize: 14, color: cs.onSurface),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        account.needsTokenBinding
                            ? 'Needs token binding (not supported)'
                            : 'Ready to upload',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_selected == account.email)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Active',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          PopupMenuButton<String>(
                            tooltip: 'Account actions',
                            onSelected: (value) async {
                              if (value == 'test') {
                                await _test(account);
                              }
                              if (value == 'select') {
                                try {
                                  await selectAccount(email: account.email);
                                  await _load();
                                } catch (e) {
                                  _setError(e);
                                }
                              }
                              if (value == 'remove') {
                                await _remove(account);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'select',
                                child: Text('Make active'),
                              ),
                              PopupMenuItem(
                                value: 'test',
                                child: Text('Test credential'),
                              ),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('Remove account'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      onTap: () async {
                        try {
                          await selectAccount(email: account.email);
                          await _load();
                        } catch (e) {
                          _setError(e);
                        }
                      },
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
