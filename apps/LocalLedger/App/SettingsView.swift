import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("このアプリについて") {
                    LabeledContent("保存場所", value: "このiPhone内のみ")
                    LabeledContent("アカウント", value: "不要")
                    LabeledContent("広告・解析", value: "なし")
                }

                Section {
                    NavigationLink("プライバシーポリシー") {
                        PrivacyPolicyView()
                    }
                } footer: {
                    Text("入力した家計簿データを開発者や第三者へ送信しません。")
                }
            }
            .navigationTitle("設定")
        }
    }
}

private struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("プライバシーポリシー")
                    .font(.title.bold())
                Text("最終更新: 2026-10-06")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    Text("データの保存").font(.headline)
                    Text("入力した金額、カテゴリ、日付、メモは利用者のiPhone内だけに保存されます。開発者のサーバーや第三者のクラウドへ送信しません。")

                    Text("収集・追跡").font(.headline)
                    Text("個人情報、広告識別子、位置情報、連絡先、写真、閲覧履歴などを収集しません。広告SDK、解析SDK、トラッキングSDKを使用しません。")

                    Text("第三者提供").font(.headline)
                    Text("利用者のデータを第三者へ販売、共有、提供しません。")

                    Text("削除").font(.headline)
                    Text("「記録」画面から記録を削除できます。「すべての記録を削除」では全記録を削除できます。アプリを削除すると、アプリが端末内に保存したデータも削除されます。")

                    Text("外部サービス").font(.headline)
                    Text("アカウント作成、外部API、クラウド同期を使用しません。")
                }
            }
            .padding()
        }
        .navigationTitle("プライバシー")
        .navigationBarTitleDisplayMode(.inline)
    }
}
