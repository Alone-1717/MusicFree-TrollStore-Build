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

/* 数据来源诊断，写进日志便于判断到底读到没有 */
NSString *MFCarPlayNativeDataDiagnosis(void);

#ifdef __cplusplus
}
#endif
