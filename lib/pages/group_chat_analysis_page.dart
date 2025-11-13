import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';
import 'group_chat_detail_page.dart';

class GroupChatAnalysisPage extends StatefulWidget {
  const GroupChatAnalysisPage({super.key});

  @override
  State<GroupChatAnalysisPage> createState() => _GroupChatAnalysisPageState();
}

class _GroupChatAnalysisPageState extends State<GroupChatAnalysisPage> {
  late final GroupChatService _groupChatService;
  List<GroupChatInfo> _allGroups = [];
  List<GroupChatInfo> _filteredGroups = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  
  // 添加静态缓存变量，用于存储群聊数据
  static List<GroupChatInfo>? _cachedGroupChats;

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);
    _loadGroupChats();
    _searchController.addListener(_filterGroups);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadGroupChats() async {
    // 首先检查缓存是否存在
    if (_cachedGroupChats != null) {
      setState(() {
        _allGroups = _cachedGroupChats!;
        _filteredGroups = _cachedGroupChats!;
        _isLoading = false;
      });
      return;
    }

    try {
      final groups = await _groupChatService.getGroupChats();
      // 保存到缓存
      _cachedGroupChats = groups;
      setState(() {
        _allGroups = groups;
        _filteredGroups = groups;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载群聊列表失败: $e'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // 添加刷新方法
  Future<void> _refreshGroupChats() async {
    setState(() {
      _isLoading = true;
    });
    // 清除缓存
    _cachedGroupChats = null;
    // 重新加载数据
    await _loadGroupChats();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('刷新成功'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _filterGroups() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredGroups = _allGroups
          .where((group) => group.displayName.toLowerCase().contains(query))
          .toList();
    });
  }

  // 生成随机颜色，根据群聊名称生成固定的颜色
  Color _getGroupColor(String groupName) {
    final int hash = groupName.hashCode;
    final List<Color> colors = [
      Colors.blue.shade600,
      Colors.green.shade600,
      Colors.purple.shade600,
      Colors.orange.shade600,
      Colors.red.shade600,
      Colors.teal.shade600,
      Colors.indigo.shade600,
      Colors.pink.shade600,
    ];
    return colors[hash.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊分析'),
        backgroundColor: theme.primaryColor,
        elevation: 0,
        // 添加刷新按钮
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshGroupChats,
            tooltip: '刷新群聊列表',
            color: Colors.white,
            splashRadius: 24,
          ),
        ],
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(16),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
        ),
        child: Column(
          children: [
            // 美化搜索框
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: '搜索群聊',
                    labelStyle: TextStyle(
                      color: theme.hintColor,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      color: theme.hintColor,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const _LoadingState()
                  : _filteredGroups.isEmpty
                      ? const _EmptyState()
                      : _buildGroupList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupList() {
    return RefreshIndicator(
      onRefresh: _refreshGroupChats,
      edgeOffset: 0,
      color: Theme.of(context).primaryColor,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _filteredGroups.length,
        itemBuilder: (context, index) {
          final group = _filteredGroups[index];
          final groupColor = _getGroupColor(group.displayName);
          
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.only(bottom: 12),
            child: Card(
              elevation: 2,
              shadowColor: Colors.black.withOpacity(0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: InkWell(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => GroupChatDetailPage(groupInfo: group),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.black.withOpacity(0.05),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // 美化群聊图标
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: groupColor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.group,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              group.displayName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                overflow: TextOverflow.ellipsis,
                              ),
                              maxLines: 1,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '成员: ${group.memberCount}人',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 添加进入详情页的指示图标
                      Icon(
                        Icons.chevron_right,
                        color: Colors.grey.shade400,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// 美化加载状态组件
class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const CircularProgressIndicator(
              strokeWidth: 4,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '加载中...',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}

// 美化空状态组件
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.group_outlined,
              size: 50,
              color: Colors.grey.shade400,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '未找到群聊',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '尝试使用其他关键词搜索',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}