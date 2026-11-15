/*
 * MFCarPlayNativeData.h — CarPlay 原生数据源（不依赖 React Native）
 *
 * 为什么需要它：
 *   11142620 真机日志证明，CarPlay 场景以 intent background 冷启动时，
 *   RN 运行时从未初始化（bridge init / carPlayJSReady 零出现），
 *   所以"等 JS 推歌单"这条路在车机上是死的。
 *
 * 本类直接读 App 自己的持久化数据（MMKV / 文件），完全绕开 RN：
 *   - 歌单列表：来自 MMKV 的 musicSheet 索引
 *   - 歌单曲目：来自 MMKV 的 sheet 详情
 *   - 当前播放：来自 trackPlayer 的持久化状态
 *
 * 读取失败一律返回空数组，绝不抛异常 —— 车机上宁可显示"暂无歌单"，
 * 也不能因为读数据把场景搞崩。
 */
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 返回 @[@{@"id":NSString, @"title":NSString, @"count":NSNumber}, ...] */
NSArray<NSDictionary *> *MFCarPlayNativeSheets(void);

/* 返回 @[@{@"id":NSString, @"title":NSString, @"artist":NSString}, ...] */
NSArray<NSDictionary *> *MFCarPlayNativeTracks(NSString *sheetId);

/*
 * 11142649：最近播放
 *
 * 数据源是 JS 侧 src/core/musicHistory.ts 用的 MMKV：
 *   实例 = "music.MusicHistory"，key = "history"
 *   值是 IMusic.IMusicItem[] 的 JSON 数组（最新在前）
 *
 * 完全原生读取，不需要 RN 运行时 —— 车机冷启动也能显示。
 * limit <= 0 表示不限制。
 */
NSArray<NSDictionary *> *MFCarPlayNativeHistory(NSUInteger limit);

/*
 * 11142649：搜索
 *
 * 遍历所有本地歌单（LocalSheet.<sheetId>）的曲目，
 * 对 title / artist 做**不区分大小写**的子串匹配。
 *
 * 为什么不走 RN 的 searchPage：
 *   车机冷启动时 RN 运行时未初始化，主 App 没打开就搜不了。
 *   本地歌单的曲目都在 MMKV 里，原生直接遍历即可。
 *   （联网搜插件源需要 RN + 网络，不在车机路径上）
 *
 * query 为空时返回空数组。
 */
NSArray<NSDictionary *> *MFCarPlayNativeSearchTracks(NSString *query);

/* 数据来源诊断，写进日志便于判断到底读到没有 */
NSString *MFCarPlayNativeDataDiagnosis(void);

#ifdef __cplusplus
}
#endif
