import SwiftUI

struct HotwordsManagementView: View {
    @State private var settings = SettingsManager.shared
    @State private var presetsManager = HotwordPresetsManager.shared
    
    @State private var showEditSheet = false
    @State private var editingCategory: HotwordCategory? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部
            HStack {
                Text(loc("hotwords_management"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(.regularMaterial)
            
            Divider()
            
            // 内容
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // 1. 热词生效权重（全局生效，单行简洁排版）
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc("hotwords_weight"))
                                    .font(.headline)
                                Text(loc("hotwords_weight_desc"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()

                            HStack(spacing: 8) {
                                Slider(value: $settings.hotwordsScore, in: 1.0...5.0, step: 0.1)
                                    .controlSize(.small)
                                    .frame(width: 140)
                                
                                Text(String(format: "%.1f", settings.hotwordsScore))
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                                    .foregroundStyle(.orange)
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 1))

                    Divider()
                    
                    // 2. 自定义热词
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc("global_custom_hotwords"))
                            .font(.headline)
                        Text(loc("global_custom_hotwords_desc"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        TextEditor(text: $settings.hotwords)
                            .font(.body)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(loc("industry_hotwords_management"))
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                editingCategory = nil
                                showEditSheet = true
                            }) {
                                Label(loc("add_industry"), systemImage: "plus")
                            }
                        }
                        
                        ForEach(presetsManager.categories) { cat in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cat.name).font(.subheadline).bold()
                                    Text(cat.wordsString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                
                                Button(loc("edit")) {
                                    editingCategory = cat
                                    showEditSheet = true
                                }
                                
                                Button(loc("delete")) {
                                    presetsManager.categories.removeAll { $0.id == cat.id }
                                    presetsManager.save()
                                }
                                .foregroundStyle(.red)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 550, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showEditSheet) {
            CategoryEditSheet(category: $editingCategory) { newCat in
                if let idx = presetsManager.categories.firstIndex(where: { $0.id == newCat.id }) {
                    presetsManager.categories[idx] = newCat
                } else {
                    presetsManager.categories.append(newCat)
                }
                presetsManager.save()
                showEditSheet = false
            } onCancel: {
                showEditSheet = false
            }
        }
        .navigationTitle(loc("hotwords_management"))
    }
}

struct CategoryEditSheet: View {
    @Binding var category: HotwordCategory?
    let onSave: (HotwordCategory) -> Void
    let onCancel: () -> Void
    
    @State private var name: String = ""
    @State private var words: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(category == nil ? loc("add_industry") : loc("edit"))
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("industry_name"))
                    .font(.caption)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("industry_words"))
                    .font(.caption)
                TextEditor(text: $words)
                    .font(.body)
                    .frame(height: 120)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
            
            HStack {
                Spacer()
                Button(loc("cancel"), action: onCancel)
                Button(category == nil ? loc("add") : loc("save")) {
                    let id = category?.id ?? UUID().uuidString
                    let wordList = words.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    let newCat = HotwordCategory(id: id, name: name, words: wordList)
                    onSave(newCat)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || words.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            if let cat = category {
                name = cat.name
                words = cat.wordsString
            }
        }
    }
}
