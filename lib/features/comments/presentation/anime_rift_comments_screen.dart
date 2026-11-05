import 'package:flutter/material.dart';

import '../../../core/extensions/providers/anime_rift_comments.dart';
import '../../../core/extensions/providers/anime_rift_provider.dart';

/// Uses Rift's own gateway/account. Never reads or writes Witcher's Firestore.
class AnimeRiftCommentsScreen extends StatefulWidget {
  const AnimeRiftCommentsScreen({
    super.key,
    required this.provider,
    required this.target,
  });

  final AnimeRiftProvider provider;
  final AnimeRiftCommentTarget target;

  @override
  State<AnimeRiftCommentsScreen> createState() =>
      _AnimeRiftCommentsScreenState();
}

class _AnimeRiftCommentsScreenState extends State<AnimeRiftCommentsScreen> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<AnimeRiftComment> _comments = const [];
  bool _initialLoading = true;
  bool _moreLoading = false;
  bool _hasMore = false;
  bool _posting = false;
  bool _linked = false;
  int _nextPage = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _hasMore &&
        !_moreLoading &&
        !_initialLoading &&
        _scroll.position.extentAfter < 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _initialLoading = true;
      _error = null;
    });
    try {
      final linked = await widget.provider.restoreAccountSession();
      final page = await widget.provider.loadComments(widget.target);
      if (!mounted) return;
      setState(() {
        _linked = linked;
        _comments = page.items;
        _hasMore = page.hasMore;
        _nextPage = 1;
        _initialLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _initialLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_moreLoading || !_hasMore) return;
    setState(() => _moreLoading = true);
    try {
      final page = await widget.provider.loadComments(
        widget.target,
        page: _nextPage,
      );
      if (!mounted) return;
      setState(() {
        final known = _comments.map((comment) => comment.id).toSet();
        _comments = [
          ..._comments,
          ...page.items.where((comment) => known.add(comment.id)),
        ];
        _hasMore = page.hasMore;
        _nextPage++;
      });
    } catch (error) {
      if (mounted) _message(error);
    } finally {
      if (mounted) setState(() => _moreLoading = false);
    }
  }

  void _message(Object error) {
    final message = error is FormatException
        ? 'تعذر قراءة بيانات تعليقات AnimeRift.'
        : error.toString();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _publish() async {
    final text = _composer.text.trim();
    if (!_linked || _posting || text.isEmpty) return;
    setState(() => _posting = true);
    try {
      await widget.provider.publishComment(widget.target, text);
      if (!mounted) return;
      _composer.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أُرسل التعليق إلى AnimeRift.')),
      );
      await _reload();
    } catch (error) {
      if (mounted) _message(error);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  void _openReplies(AnimeRiftComment comment) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeRiftCommentsScreen(
          provider: widget.provider,
          target: widget.target.replies(comment.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.target.parentId == null
              ? 'تعليقات ${widget.target.title}'
              : 'الردود',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _initialLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('تعذّر تحميل تعليقات AnimeRift.'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _reload,
                          child: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _comments.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _comments.length) {
                          if (_moreLoading) {
                            return const Padding(
                              padding: EdgeInsets.all(14),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          return _comments.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(32),
                                  child: Center(
                                    child: Text('لا توجد تعليقات بعد.'),
                                  ),
                                )
                              : const SizedBox(height: 12);
                        }
                        final comment = _comments[index];
                        return ListTile(
                          key: ValueKey('rift-comment-${comment.id}'),
                          title: Text(
                            comment.author,
                            style: theme.textTheme.titleSmall,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              comment.spoiler
                                  ? ExpansionTile(
                                      tilePadding: EdgeInsets.zero,
                                      title: const Text(
                                        'تعليق يحتوي حرقًا — اضغط للعرض',
                                      ),
                                      children: [Text(comment.text)],
                                    )
                                  : Text(comment.text),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('👍 ${comment.likes}'),
                                  TextButton.icon(
                                    onPressed: () => _openReplies(comment),
                                    icon: const Icon(
                                      Icons.reply_rounded,
                                      size: 17,
                                    ),
                                    label: Text('الردود ${comment.replies}'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: _linked
                  ? Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('rift-comment-input'),
                            controller: _composer,
                            maxLength: 5000,
                            maxLines: 3,
                            minLines: 1,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: 'اكتب تعليقًا...',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'نشر التعليق',
                          onPressed: _posting ? null : _publish,
                          icon: _posting
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
                    )
                  : const Text(
                      'اربط حساب AnimeRift من الإعدادات لنشر التعليقات.',
                      textAlign: TextAlign.center,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
