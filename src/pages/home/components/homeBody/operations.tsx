import { useI18N } from "@/core/i18n";
import { ROUTE_PATH, useNavigate } from "@/core/router";
import rpx from "@/utils/rpx";
import React from "react";
import { StyleSheet, View } from "react-native";
import ActionButton from "../ActionButton";

export default function Operations() {
    const navigate = useNavigate();
    const { t } = useI18N();

    /*
     * 11142656：移除「榜单」和「本地音乐」两个入口。
     *
     * 保留：
     *   推荐歌单 -> RECOMMEND_SHEETS
     *   播放历史 -> HISTORY
     *
     * 移除原因：用户要求精简首页。
     * 注意：路由与页面代码保留（ROUTE_PATH.TOP_LIST / LOCAL 仍存在），
     *      只是首页不再有入口，后续需要可随时加回。
     */
    const actionButtons = [
        {
            iconName: "fire",
            title: t("home.recommendSheet"),
            action() {
                navigate(ROUTE_PATH.RECOMMEND_SHEETS);
            },
        },
        {
            iconName: "clock-outline",
            title: t("home.playHistory"),
            action() {
                navigate(ROUTE_PATH.HISTORY);
            },
        },
    ] as const;

    return (
        <View style={styles.container}>
            {actionButtons.map((action, index) => (
                <ActionButton
                    style={[
                        styles.actionButtonStyle,
                        index % 4 ? styles.actionMarginLeft : null,
                    ]}
                    key={action.title}
                    {...action}
                />
            ))}
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        width: rpx(750),
        paddingHorizontal: rpx(24),
        marginVertical: rpx(32),
        flexDirection: "row",
        flexWrap: "wrap",
    },
    /* 11142656：只剩两个按钮，宽度改成等分（750 - 48 padding - 24 gap）/ 2 */
    actionButtonStyle: {
        width: rpx(339),
        height: rpx(160),
        borderRadius: rpx(18),
    },
    actionMarginLeft: {
        marginLeft: rpx(24),
    },
});
