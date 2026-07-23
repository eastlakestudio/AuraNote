import SwiftUI
import WhisperKit

// MARK: - 国际化
func loc(_ key: String) -> String {
    let lang = UserDefaults.standard.string(forKey: "ui_language") ?? ""
    return (lang == "en" ? enLocale : zhLocale)[key] ?? key
}

let zhLocale: [String: String] = [
    "settings": "系统配置", "save": "保存",
    "speech_model": "语音识别模型", "downloaded": "已下载", "model_label": "模型", "redownload_hint": "点击重新下载模型", "redownload_confirm_title": "重新下载模型", "redownload_confirm_msg": "重新下载将覆盖现有模型文件，需重新从网络下载约 1.6 GB 数据。确定要继续吗？", "redownload_confirm_ok": "重新下载",
    "china_mirror": "HF-Mirror", "huggingface": "HuggingFace",
    "about_desc": "本地离线会议纪要系统  |  WhisperKit + sherpa-onnx",
    "about_copyright": "© 2026 Eastlake Studio. 保留所有权利。",
    "about_feature_desc": "听纪是一款完全本地离线运行的智能会议纪要系统。\n基于 WhisperKit 语音识别引擎与 sherpa-onnx 声纹分离技术，\n支持实时录音转写、离线高精度转写、多说话人声纹分离与匹配。\n所有音频数据均在本地处理，无需联网，保障隐私安全。",
    "about_feature_desc_en": "AuraNote is a fully offline intelligent meeting minutes system.\nPowered by WhisperKit speech recognition and sherpa-onnx voiceprint diarization,\nit supports real-time transcription, offline high-accuracy transcription,\nand multi-speaker voiceprint separation & matching.\nAll audio data is processed locally — no internet required, ensuring complete privacy.",
    "copyright": "© 2026 Eastlake Studio",
    "model_name": "模型名称",
    "zhipu": "智谱AI",
    "err_model_not_downloaded": "语音模型未下载\n请前往「系统配置」选择存储路径并下载模型",
    "err_model_load_failed": "语音模型加载失败\n请前往「系统配置」重新下载模型",
    "err_start_record_failed": "启动录音失败",
    "err_offline_transcribe_failed": "离线转写失败\n可尝试在「系统配置」中重新下载模型",
    "err_download_failed": "模型下载失败",
    "err_retry_hint": "可尝试在「系统配置」中重新下载模型",
    "err_permission_denied": "权限被拒绝",
    "err_create_meeting_failed": "创建会议失败",
    "err_unsupported_audio_format": "不支持的音频格式",
    "err_file_copy_failed": "文件复制失败",
    "click_to_download": "点击下载",
    "voice_model_not_ready": "语音模型未下载",
    "model_not_downloaded_banner_title": "语音模型尚未下载",
    "model_not_downloaded_banner_desc": "点击此处前往系统配置下载模型，完成后即可使用全部功能",
    "voice_model_ready": "已就绪",
    "model_downloading": "正在下载语音模型...",
    "settings_saved": "配置已保存",
    "download_error_label": "下载失败",
    "status_ready": "准备就绪",
    "permission_hint": "请前往「系统设置 - 隐私与安全性 - 麦克风/语音识别」中开启权限。",
    "model_ready_suffix": "已就绪",
    "app_title": "听纪",
    "personnel_voiceprint": "人员与声纹",
    "personnel_voiceprint_help": "全局人员与声纹管理",
    "start_meeting": "开始会议",
    "permission_insufficient": "权限不足",
    "confirm": "确定",
    "no_meetings": "暂无会议记录",
    "start_meeting_hint": "点击右上角「开始会议」选择录音模式",
    "delete_meeting": "删除会议",
    "save_recording": "另存录音文件",
    "status_recording": "录音中",
    "status_pending_diarization": "未分离",
    "status_processing_llm": "分离未完成",
    "status_completed": "完成分离",
    "delete_confirm_detail": "以下关联会议将被删除（含录音文件、转写文本和说话人分离数据），此操作不可撤销。在删除前，您可以点击录音文件右侧的导出按钮手动导出所需文件。",
    "audio_file_label": "录音文件",
    "voice_clips_label": "语音剪辑",
    "created_label": "创建",
    "extend_label": "延续",
    "cancel": "取消",
    "confirm_delete": "确认删除",
    "switching_model_hint": "正在下载其他模型",
    "review_title": "会议回顾",
    "transcribing_progress": "转写中...",
    "transcribing_segments": "已完成 %d 段 · %d%%",
    "transcribing_segments_done": "已完成 %d / %d 段 (%d%%)",
    "transcribing_segments_with_time": "已完成 %d 段 · %@ / %@ (%d%%)",
    "transcribing_placeholder": "等待转写中...",
    "debug_log": "调试日志",
    "analyzing": "分析中...",
    "reanalyze": "重新分析",
    "continue_analysis": "继续分析",
    "copy": "拷贝",
    "copy_hint": "拷贝纪要到剪贴板",
    "export": "导出",
    "export_audio": "导出音频",
    "done": "完成",
    "back": "返回",
    "meeting_inspector": "会议属性检查器",
    "confirm_retranscribe": "确认重新转写",
    "confirm_retranscribe_msg": "已有 %d 段转写结果，重新转写将覆盖现有内容且耗时较长（约 5-10 分钟），是否继续？",
    "transcribing_hint": "正在使用本地大模型高精度转写...",
    "transcript_missing": "转写数据缺失",
    "transcript_missing_hint": "录音文件可能尚未完成离线转写",
    "rerun_transcription": "重新运行离线转写",
    "audio_file_not_found": "录音文件不存在",
    "no_transcript": "暂无转写内容",
    "load_from_db": "从数据库加载",
    "segments_count": "%d 段",
    "export_meeting_record": "导出会议记录",
    "status_pending": "待分离",
    "status_ai_processing": "AI 处理中",
    "status_done": "已完成",
    "debug_log_empty": "暂无日志",
    "refresh": "刷新",
    "external_import": "外部导入",
    "meeting_info": "会议信息",
    "recording": "录音中",
    "listening": "正在聆听...",
    "stop_recording": "停止录音",
    "merge_prev": "合并到上一段",
    "attendees_section": "参会人",
    "global_staff": "全局人员",
    "new_speaker_ellipsis": "新建说话人...",
    "new_voiceprint": "新建声纹人",
    "name": "姓名",
    "confirm_delete_person": "确认删除",
    "confirm_delete_person_msg": "确定删除「%@」吗？此操作不可撤销。\n该人员的声纹向量和发言记录关联将被清除。",
    "delete_speech_clip": "删除发言",
    "delete_speech_clip_msg": "确定删除这条发言记录吗？此操作不可撤销。",
    "delete_meeting_clips": "删除该会议发言",
    "delete_meeting_clips_msg": "确定删除「%@」的全部 %d 条发言记录吗？此操作不可撤销。",
    "clear_all_clips": "全部清空",
    "clear_all_clips_msg": "确定清空所有人员的全部发言记录吗？此操作不可撤销。",
    "clear_voiceprint": "清除声纹",
    "clear_voiceprint_msg": "确定清除「%@」的声纹特征吗？清除后需重新录制/分析才能再次匹配。",
    "voiceprint_registered": "已注册声纹",
    "voiceprint_not_registered": "未注册声纹",
    "clear_all_voiceprints": "清除所有声纹",
    "clear_all_voiceprints_msg": "确定清除所有联系人的声纹特征吗？此操作不可撤销。",
    "batch_select": "批量选择",
    "select_all": "全选",
    "batch_delete_count": "删除(%d)",
    "batch_delete_clips": "批量删除发言",
    "batch_delete_clips_msg": "确定删除选中的 %d 条发言记录吗？此操作不可撤销。",
    "batch_delete_contacts": "批量删除发言人",
    "batch_delete_contacts_msg": "确定删除选中的 %d 位发言人吗？此操作不可撤销。",
    "personnel_list": "人员列表",
    "add_person": "添加人员",
    "no_personnel": "暂无人员",
    "edit": "编辑",
    "delete": "删除",
    "person_attributes": "人员属性",
    "role": "职位",
    "org": "组织",
    "personnel_overview": "人员总览",
    "total": "总计",
    "people_unit": "人",
    "sentences_unit": "句",
    "no_speech_records": "暂无发言记录",
    "speech_count_fmt": "%d 条发言 · %d 场会议",
        "speech_count_fmt_short": "%d 条",
    "no_company": "未分组",
    "new_meeting": "新建会议",
    "meeting_language": "会议语言",
    "chinese": "中文",
    "meeting_topic": "会议主题",
    "enter_topic": "输入会议主题",
    "start_time": "开始时间",
    "meeting_location": "会议地点",
    "enter_location": "输入地点",
    "attendees": "参会人",
    "select_from_personnel": "从全局人员库选择...",
    "audio_source": "音频来源",
    "live_recording": "实时录音",
    "audio_file": "音频文件",
    "no_audio_selected": "未选择音频文件",
    "select_audio_file": "选择音频文件",
    "extend_meeting": "延续历史会议",
    "start": "开始",
    "meeting_properties": "会议属性",
    "rename_attendee": "重命名参会人",
    "new_name": "新名称",
    "topic": "会议主题",
    "end_time": "结束时间",
    "location_label": "地点",
    "meeting_place": "会议地点",
    "search_person": "搜索人员...",
    "new_personnel": "新建人员",
    "select_from_db": "从全局人员库多选",
    "speaker_matching": "说话人匹配",
    "dictionary": "字典",
    "no_unmatched": "暂无未匹配说话人",
    "bind_to_attendee": "绑定到参会人",
    "bind": "绑定",
    "speech_stats": "发言统计",
    "no_data": "暂无数据",
    "reassign": "重新分配到参会人",
    "rename": "重命名",
    "remove_from_attendees": "从参会人中移除",
    "person_name": "人名",
    "name_required": "姓名（必填）",
    "role_hint": "如：总经理、开发工程师",
    "org_hint": "如：阿里巴巴、腾讯",
    "create": "创建",
    "select_attendees": "选择参会人",
    "search": "搜索...",
    "no_match": "无匹配人员",
    "new": "新建",
    "selected_count": "已选 %d 人",
    "confirm_btn": "确认",
    "initializing": "正在初始化...",
    "error": "错误",
    "filter_prefix": "过滤: %@",
    "play": "播放",
    "other_speakers": "其他说话人",
    "new_ellipsis": "新建...",
    "new_speaker": "新建说话人",
    "merge": "合并",
    "duration_min_sec": "%d分%d秒",
    "duration_sec_only": "%d秒",
    "copy_topic": "会议主题: %@",
    "copy_location": "会议地点: %@",
    "copy_time": "开始时间: %@",
    "copy_attendees": "参会人员: %@",
    "not_specified": "未指定",
    "export_record_title": "会议记录",
    "record_duration_fmt": "录音时长: %@",
    "follow_system": "跟随系统",
    "simplified_chinese": "简体中文",
    "path_not_exist": "不存在",
    "download_timeout": "下载超时，请检查网络连接",
    "no_attendees_yet": "暂无参会人",
    "sentences_count_fmt": "%d句",
    "people_count_fmt": "%d人",
    "model_not_downloaded_settings": "模型未下载，请前往系统设置选择路径并进行下载。",
    "model_load_failed": "模型加载失败，请检查网络后重试",
    "model_not_loaded": "模型尚未加载完成",
    "audio_file_not_found_name": "音频文件不存在: %@",
    "player_init_failed": "初始化播放器失败: %@",
    "mic_permission_required": "需要麦克风权限才能录制会议",
    "mic_permission_denied": "麦克风权限被拒绝",
    "default_meeting_title": "会议记录_%@",
    "audio_file_not_found_diag": "录音文件未找到（%@.* 不存在于 Documents 目录）",
    "audio_file_missing_diag": "录音文件 %@ 不存在，但发现相关文件: %@",
    // 算法参数配置
    "algo_params": "算法参数",
    "algo_params_desc": "调整语音识别与声纹分离算法的基础参数，修改后即时生效。",
    "audio_processing": "音频处理",
    "silence_threshold": "静音阈值",
    "silence_threshold_desc": "振幅低于此值视为无声",
    "pause_window": "停顿时长",
    "pause_window_desc": "无声持续此秒数后触发文本固化",
    "live_transcribe_interval": "实时轮询间隔",
    "live_transcribe_interval_desc": "实时转写后台轮询间隔",
    "noise_gate": "噪声门限",
    "noise_gate_desc": "峰值低于此值不做增益",
    "target_peak": "目标峰值",
    "target_peak_desc": "有语音时的目标电平 (-3dBFS)",
    "max_gain": "最大增益",
    "max_gain_desc": "语音增强的最大放大倍数",
    "base_gain": "基础增益",
    "base_gain_desc": "中高电平语音的基础增益",
    "vad_params": "语音活动检测",
    "voice_segmentation": "语音分段与转写",
    "speaker_recognition": "声纹处理",
    "speaker_diarization": "声纹分离",
    "clustering_threshold": "聚类阈值",
    "clustering_threshold_desc": "余弦距离阈值 (0~2)：越低越细分，说话人越多",
    "incremental_clustering_distance": "增量聚类距离",
    "incremental_clustering_distance_desc": "逐段合并阈值 (0~2)：越低越保守，避免异人误合并",
    "cluster_merge_distance": "聚类合并距离",
    "cluster_merge_distance_desc": "簇级合并阈值 (0~2)：平均声纹更稳定，可比逐段阈值宽松",
    "max_diarization_speakers": "最大说话人数",
    "matching_threshold": "匹配阈值",
    "matching_threshold_desc": "声纹匹配的最低余弦相似度",
    "high_confidence_threshold": "高置信度阈值",
    "high_confidence_threshold_desc": "高于此值自动绑定到已知联系人",
    "live_matching_threshold": "实时匹配阈值",
    "live_matching_threshold_desc": "实时录音中声纹匹配的余弦相似度最低分（短片段声纹质量较低，阈值可设更低）",
    "min_duration_on": "最短语音段",
    "min_duration_on_desc": "sherpa-onnx 声纹分离的最短语音段时长（秒），太短会产生碎段",
    "min_duration_off": "最小静音间隔",
    "min_duration_off_desc": "sherpa-onnx 声纹分离的最小静音间隔（秒），更小 = 更精细的切分",
    "consumer_poll_interval": "消费轮询间隔",
    "consumer_poll_interval_desc": "离线转写消费者从队列取数据的间隔",
    "max_chunk_duration": "最大片段时长",
    "max_chunk_duration_desc": "实时录音单段最大秒数，超时强制切分",
    "reset_defaults": "恢复默认",
    "unit_seconds": "秒",
    "unit_times": "倍",
    // 滑动条左右提示
    "hint_more_precise": "更精准",
    "hint_more_lenient": "更宽松",
    "hint_shorter": "更短",
    "hint_longer": "更长",
    "hint_lower": "更低",
    "hint_higher": "更高",
    "hint_quieter": "更安静",
    "hint_louder": "更大声",
    "hint_more_strict": "更严格",
    "hint_more_tolerant": "更宽容",
    "hint_fewer_speakers": "更少人",
    "hint_more_speakers": "更多人",
    "hint_more_sensitive": "更灵敏",
    "hint_more_stable": "更稳定",
    "hint_finer_grained": "更精细",
    "hint_more_relaxed": "更宽松",
] 
let enLocale: [String: String] = [
    "settings": "Settings", "save": "Save",
    "speech_model": "Speech Recognition", "downloaded": "Downloaded",
    "cache": "Cache", "model_label": "Model", "redownload_hint": "Click to re-download", "redownload_confirm_title": "Re-download Model", "redownload_confirm_msg": "This will overwrite the existing model and re-download ~1.6 GB from the network. Are you sure you want to continue?", "redownload_confirm_ok": "Re-download",
    "china_mirror": "HF-Mirror", "huggingface": "HuggingFace",
    "about_desc": "Offline Meeting Minutes  |  WhisperKit + sherpa-onnx",
    "about_copyright": "© 2026 Eastlake Studio. All rights reserved.",
    "about_feature_desc": "AuraNote is a fully offline intelligent meeting minutes system.\nPowered by WhisperKit speech recognition and sherpa-onnx voiceprint diarization,\nit supports real-time transcription, offline high-accuracy transcription,\nand multi-speaker voiceprint separation & matching.\nAll audio data is processed locally — no internet required, ensuring complete privacy.",
    "about_feature_desc_en": "AuraNote is a fully offline intelligent meeting minutes system.\nPowered by WhisperKit speech recognition and sherpa-onnx voiceprint diarization,\nit supports real-time transcription, offline high-accuracy transcription,\nand multi-speaker voiceprint separation & matching.\nAll audio data is processed locally — no internet required, ensuring complete privacy.",
    "copyright": "© 2026 Eastlake Studio",
    "model_name": "Model Name",
    "zhipu": "Zhipu AI",
    "err_model_not_downloaded": "Voice model not downloaded\nPlease go to Settings to select a storage path and download the model",
    "err_model_load_failed": "Voice model failed to load\nPlease go to Settings to re-download the model",
    "err_start_record_failed": "Failed to start recording",
    "err_offline_transcribe_failed": "Offline transcription failed\nTry re-downloading the model in Settings",
    "err_download_failed": "Model download failed",
    "err_retry_hint": "Try re-downloading the model in Settings",
    "err_permission_denied": "Permission denied",
    "err_create_meeting_failed": "Failed to create meeting",
    "err_unsupported_audio_format": "Unsupported audio format",
    "err_file_copy_failed": "File copy failed",
    "click_to_download": "Download",
    "voice_model_not_ready": "Voice model not downloaded",
    "model_not_downloaded_banner_title": "Voice model not downloaded",
    "model_not_downloaded_banner_desc": "Tap to download the model in Settings to unlock all features",
    "voice_model_ready": "Ready",
    "model_downloading": "Downloading voice model...",
    "settings_saved": "Settings saved",
    "download_error_label": "Download failed",
    "status_ready": "Ready",
    "permission_hint": "Please enable permissions in System Settings - Privacy & Security - Microphone/Audio Recognition.",
    "model_ready_suffix": "Ready",
    "app_title": "AuraNote",
    "personnel_voiceprint": "Personnel & Voiceprint",
    "personnel_voiceprint_help": "Global personnel and voiceprint management",
    "start_meeting": "Start Meeting",
    "permission_insufficient": "Insufficient Permissions",
    "confirm": "OK",
    "no_meetings": "No meetings yet",
    "start_meeting_hint": "Click 'Start Meeting' in the top right to choose a recording mode",
    "delete_meeting": "Delete Meeting",
    "save_recording": "Save Recording File",
    "status_recording": "Recording",
    "status_pending_diarization": "Not Diarized",
    "status_processing_llm": "Diarization Incomplete",
    "status_completed": "Diarized",
    "delete_confirm_detail": "The following linked meetings will be deleted (including recordings, transcripts, and speaker diarization data). This operation cannot be undone. Before deleting, you can click the export button next to a recording file to manually export it.",
    "audio_file_label": "Audio File",
    "voice_clips_label": "Voice Clips",
    "created_label": "Created",
    "extend_label": "Extend",
    "cancel": "Cancel",
    "confirm_delete": "Confirm Delete",
    "switching_model_hint": "Downloading a different model",
    "review_title": "Meeting Review",
    "transcribing_progress": "Transcribing...",
    "transcribing_segments": "%d segments · %d%%",
    "transcribing_segments_done": "%d / %d segments (%d%%)",
    "transcribing_segments_with_time": "%d segments · %@ / %@ (%d%%)",
    "transcribing_placeholder": "Awaiting transcription...",
    "debug_log": "Debug Log",
    "analyzing": "Analyzing...",
    "reanalyze": "Re-analyze",
    "continue_analysis": "Continue Analysis",
    "copy": "Copy",
    "copy_hint": "Copy minutes to clipboard",
    "export": "Export",
    "export_audio": "Export Audio",
    "done": "Done",
    "back": "Back",
    "meeting_inspector": "Meeting Inspector",
    "confirm_retranscribe": "Confirm Re-transcription",
    "confirm_retranscribe_msg": "There are %d existing transcript segments. Re-transcription will overwrite current content and take a long time (~5-10 min). Continue?",
    "transcribing_hint": "Transcribing with local AI model...",
    "transcript_missing": "Transcript Data Missing",
    "transcript_missing_hint": "Recording may not have completed offline transcription yet",
    "rerun_transcription": "Re-run Offline Transcription",
    "audio_file_not_found": "Audio file not found",
    "no_transcript": "No Transcript Content",
    "load_from_db": "Load from Database",
    "segments_count": "%d segments",
    "export_meeting_record": "Export Meeting Record",
    "status_pending": "Pending Diarization",
    "status_ai_processing": "AI Processing",
    "status_done": "Completed",
    "debug_log_empty": "No logs yet",
    "refresh": "Refresh",
    "external_import": "External Import",
    "meeting_info": "Meeting Info",
    "recording": "Recording",
    "listening": "Listening...",
    "stop_recording": "Stop Recording",
    "merge_prev": "Merge with Previous",
    "attendees_section": "Attendees",
    "global_staff": "All Personnel",
    "new_speaker_ellipsis": "New Speaker...",
    "new_voiceprint": "New Voiceprint",
    "name": "Name",
    "confirm_delete_person": "Confirm Delete",
    "confirm_delete_person_msg": "Are you sure you want to delete '%@'? This cannot be undone.\nThe person's voiceprint and speech record associations will be cleared.",
    "delete_speech_clip": "Delete Clip",
    "delete_speech_clip_msg": "Delete this speech record? This cannot be undone.",
    "delete_meeting_clips": "Delete Meeting Clips",
    "delete_meeting_clips_msg": "Delete all %d clips from '%@'? This cannot be undone.",
    "clear_all_clips": "Clear All",
    "clear_all_clips_msg": "Clear all speech records for all personnel? This cannot be undone.",
    "clear_voiceprint": "Clear Voiceprint",
    "clear_voiceprint_msg": "Clear the voiceprint for '%@'? Re-recording/re-analysis will be needed for matching again.",
    "voiceprint_registered": "Voiceprint registered",
    "voiceprint_not_registered": "No voiceprint",
    "clear_all_voiceprints": "Clear All Voiceprints",
    "clear_all_voiceprints_msg": "Clear all voiceprints for all contacts? This cannot be undone.",
    "batch_select": "Batch Select",
    "select_all": "Select All",
    "batch_delete_count": "Delete(%d)",
    "batch_delete_clips": "Batch Delete",
    "batch_delete_clips_msg": "Delete %d selected speech records? This cannot be undone.",
    "batch_delete_contacts": "Batch Delete Contacts",
    "batch_delete_contacts_msg": "Delete %d selected contacts? This cannot be undone.",
    "personnel_list": "Personnel List",
    "add_person": "Add Person",
    "no_personnel": "No Personnel",
    "edit": "Edit",
    "delete": "Delete",
    "person_attributes": "Attributes",
    "role": "Position",
    "org": "Organization",
    "personnel_overview": "Personnel Overview",
    "total": "Total",
    "people_unit": "",
    "sentences_unit": " sentences",
    "no_speech_records": "No Speech Records",
    "speech_count_fmt": "%d speeches · %d meetings",
        "speech_count_fmt_short": "%d clips",
    "no_company": "No Group",
    "new_meeting": "New Meeting",
    "meeting_language": "Language",
    "chinese": "中文",
    "meeting_topic": "Topic",
    "enter_topic": "Enter topic",
    "start_time": "Start Time",
    "meeting_location": "Location",
    "enter_location": "Enter location",
    "attendees": "Attendees",
    "select_from_personnel": "Select from personnel...",
    "audio_source": "Audio Source",
    "live_recording": "Live Recording",
    "audio_file": "Audio File",
    "no_audio_selected": "No audio file selected",
    "select_audio_file": "Select Audio File",
    "extend_meeting": "Extend Meeting",
    "start": "Start",
    "meeting_properties": "Meeting Properties",
    "rename_attendee": "Rename Attendee",
    "new_name": "New Name",
    "topic": "Topic",
    "end_time": "End Time",
    "location_label": "Location",
    "meeting_place": "Meeting Place",
    "search_person": "Search...",
    "new_personnel": "New Person",
    "select_from_db": "Select from personnel",
    "speaker_matching": "Speaker Matching",
    "dictionary": "Dictionary",
    "no_unmatched": "No unmatched speakers",
    "bind_to_attendee": "Bind to Attendee",
    "bind": "Bind",
    "speech_stats": "Speech Stats",
    "no_data": "No data",
    "reassign": "Reassign",
    "rename": "Rename",
    "remove_from_attendees": "Remove from Attendees",
    "person_name": "Name",
    "name_required": "Name (required)",
    "role_hint": "e.g. CEO, Developer",
    "org_hint": "e.g. Google, Apple",
    "create": "Create",
    "select_attendees": "Select Attendees",
    "search": "Search...",
    "no_match": "No matches",
    "new": "New",
    "selected_count": "%d selected",
    "confirm_btn": "Confirm",
    "initializing": "Initializing...",
    "error": "Error",
    "filter_prefix": "Filter: %@",
    "play": "Play",
    "other_speakers": "Other Speakers",
    "new_ellipsis": "New...",
    "new_speaker": "New Speaker",
    "merge": "Merge",
    "duration_min_sec": "%d min %d sec",
    "duration_sec_only": "%d sec",
    "copy_topic": "Topic: %@",
    "copy_location": "Location: %@",
    "copy_time": "Start Time: %@",
    "copy_attendees": "Attendees: %@",
    "not_specified": "Not specified",
    "export_record_title": "Meeting Minutes",
    "record_duration_fmt": "Duration: %@",
    "follow_system": "Follow System",
    "simplified_chinese": "简体中文",
    "path_not_exist": "Not Found",
    "download_timeout": "Download timed out, check network connection",
    "no_attendees_yet": "No attendees yet",
    "sentences_count_fmt": "%d sentences",
    "people_count_fmt": "%d people",
    "model_not_downloaded_settings": "Model not downloaded, please go to Settings to select a path and download.",
    "model_load_failed": "Failed to load model, please check network and retry",
    "model_not_loaded": "Model has not finished loading",
    "audio_file_not_found_name": "Audio file not found: %@",
    "player_init_failed": "Failed to initialize player: %@",
    "mic_permission_required": "Microphone permission is required to record meetings",
    "mic_permission_denied": "Microphone permission denied",
    "default_meeting_title": "Meeting Record_%@",
    "audio_file_not_found_diag": "Audio file not found (%@.* does not exist in Documents directory)",
    "audio_file_missing_diag": "Audio file %@ not found, but found related files: %@",
    // Data Storage Path
    // Algorithm Parameters
    "algo_params": "Algorithm Parameters",
    "algo_params_desc": "Adjust base parameters for speech recognition and voiceprint diarization. Changes take effect immediately.",
    "audio_processing": "Audio Processing",
    "silence_threshold": "Silence Threshold",
    "silence_threshold_desc": "Amplitude below this is treated as silence",
    "pause_window": "Pause Window",
    "pause_window_desc": "Silence duration before text is finalized",
    "live_transcribe_interval": "Live Polling Interval",
    "live_transcribe_interval_desc": "Background polling interval for live transcription",
    "noise_gate": "Noise Gate",
    "noise_gate_desc": "Peaks below this are not amplified",
    "target_peak": "Target Peak",
    "target_peak_desc": "Target level for speech (-3dBFS)",
    "max_gain": "Max Gain",
    "max_gain_desc": "Maximum amplification for speech enhancement",
    "base_gain": "Base Gain",
    "base_gain_desc": "Base gain for mid-high level speech",
    "vad_params": "Voice Activity Detection",
    "voice_segmentation": "Voice Segmentation & Transcription",
    "speaker_recognition": "Speaker Recognition",
    "speaker_diarization": "Speaker Diarization",
    "clustering_threshold": "Clustering Threshold",
    "clustering_threshold_desc": "Cosine distance (0~2): lower = more speakers",
    "incremental_clustering_distance": "Incremental Clustering Dist",
    "incremental_clustering_distance_desc": "Per-segment merge threshold (0~2): lower = more conservative",
    "cluster_merge_distance": "Cluster Merge Distance",
    "cluster_merge_distance_desc": "Cluster-level merge threshold (0~2): avg embeddings are stabler, can be looser",
    "max_diarization_speakers": "Max Speakers",
    "matching_threshold": "Matching Threshold",
    "matching_threshold_desc": "Minimum cosine similarity for voiceprint matching",
    "high_confidence_threshold": "High Confidence Threshold",
    "high_confidence_threshold_desc": "Auto-bind to known contacts above this score",
    "live_matching_threshold": "Real-time Matching Threshold",
    "live_matching_threshold_desc": "Min cosine similarity for voiceprint matching during live recording (lower for short clips)",
    "min_duration_on": "Min Speech Duration",
    "min_duration_on_desc": "Minimum speech segment duration (s) for sherpa-onnx diarization",
    "min_duration_off": "Min Silence Gap",
    "min_duration_off_desc": "Minimum silence gap (s) for sherpa-onnx diarization, smaller = finer split",
    "consumer_poll_interval": "Consumer Poll Interval",
    "consumer_poll_interval_desc": "Interval for offline transcription consumer to fetch data",
    "max_chunk_duration": "Max Chunk Duration",
    "max_chunk_duration_desc": "Max seconds per live segment, force split on timeout",
    "reset_defaults": "Reset Defaults",
    "unit_seconds": "s",
    "unit_times": "x",
    // Slider hints
    "hint_more_precise": "More Precise",
    "hint_more_lenient": "More Lenient",
    "hint_shorter": "Shorter",
    "hint_longer": "Longer",
    "hint_lower": "Lower",
    "hint_higher": "Higher",
    "hint_quieter": "Quieter",
    "hint_louder": "Louder",
    "hint_more_strict": "Stricter",
    "hint_more_tolerant": "More Tolerant",
    "hint_fewer_speakers": "Fewer Speakers",
    "hint_more_speakers": "More Speakers",
    "hint_more_sensitive": "More Sensitive",
    "hint_more_stable": "More Stable",
    "hint_finer_grained": "Finer Grained",
    "hint_more_relaxed": "More Relaxed",
]

struct SettingsView: View {
    @State private var settings = SettingsManager.shared
    @State private var showLangPicker = false
    @State private var downloadTask: Task<Void, Never>? = nil
    @State private var downloadStateVersion = 0
    @State private var showRedownloadAlert = false
    @State private var showSherpaOnnxTest = false

    private let labelWidth: CGFloat = 85

    var body: some View {
        @Bindable var settings = settings
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        HStack(spacing: 12) {
                            Text(loc("settings"))
                                .font(.title2)
                                .fontWeight(.bold)
                            Spacer()
                            Button { showLangPicker = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "globe")
                                    Text(settings.langSetting == "en" ? "EN" : "中")
                                }
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showLangPicker, arrowEdge: .bottom) {
                                VStack(spacing: 2) {
                                    Button(loc("follow_system")) { settings.langSetting = ""; showLangPicker = false }.padding(6).contentShape(Rectangle())
                                    Button(loc("simplified_chinese")) { settings.langSetting = "zh-Hans"; showLangPicker = false }.padding(6).contentShape(Rectangle())
                                    Button("English") { settings.langSetting = "en"; showLangPicker = false }.padding(6).contentShape(Rectangle())
                                }
                                .padding(6)
                                .frame(width: 110)
                            }
                            
                        }
                        .padding(.top, 16)
                        
                        // Card 1: 语音识别模型
                        VStack(alignment: .leading, spacing: 16) {
                            Label(loc("speech_model"), systemImage: "waveform.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.purple)
                            
                            VStack(spacing: 12) {
                                // Row 1: 模型名称 + 状态操作
                                HStack(spacing: 12) {
                                    Text(loc("model_label"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(width: labelWidth, alignment: .leading)
                                    
                                    Text("openai/whisper-large-v3 (1.6 GB)")
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                    
                                    Spacer()
                                    
                                    PressableButton(
                                        disabled: false,
                                        action: {
                                            if !settings.currentModelDownloading {
                                                if isModelDownloaded {
                                                    showRedownloadAlert = true
                                                } else {
                                                    downloadModel()
                                                }
                                            }
                                        }
                                    ) {
                                        HStack(spacing: 4) {
                                            if settings.currentModelDownloading {
                                                ProgressView().controlSize(.small).frame(width: 12, height: 12)
                                                Text(String(format: "%.0f%%", settings.currentModelProgress * 100))
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                Button {
                                                    downloadTask?.cancel()
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.red)
                                                        .font(.caption)
                                                }
                                                .buttonStyle(.plain)
                                            } else if isModelDownloaded {
                                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                                Text(loc("downloaded"))
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.caption)
                                            } else {
                                                Circle().fill(Color.red).frame(width: 6, height: 6)
                                                Text(loc("click_to_download"))
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                Image(systemName: "arrow.down.to.line")
                                                    .font(.caption)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .frame(minWidth: 120, maxWidth: 120)
                                        .background(settings.currentModelDownloading ? Color.blue.opacity(0.12) : (isModelDownloaded ? Color.green.opacity(0.12) : Color.blue.opacity(0.12)))
                                        .foregroundStyle(settings.currentModelDownloading ? .blue : (isModelDownloaded ? .green : .blue))
                                        .cornerRadius(6)
                                    }
                                    .help(isModelDownloaded ? loc("redownload_hint") : "")
                                }
                                
                                if let err = settings.currentModelError {
                                    HStack {
                                        Spacer().frame(width: labelWidth + 12)
                                        Text("\(loc("download_error_label")): \(err)")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.4)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                        // Card 2: sherpa-onnx 声纹分离测试
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("sherpa-onnx 测试", systemImage: "waveform.path.ecg")
                                    .font(.headline)
                                    .foregroundStyle(.blue)
                                Spacer()
                                Button {
                                    showSherpaOnnxTest = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.circle")
                                        Text("打开测试")
                                    }
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundStyle(.blue)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("使用 sherpa-onnx (ONNX Runtime) 进行离线声纹分离测试")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.4)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                        // Card 3: 算法参数配置
                        algoParamsCard
                    }
                    .padding(.horizontal, 24)
                }
                
                Divider()
                
                // About Footer
                VStack(spacing: 4) {
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(loc("about_desc"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(loc("copyright"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
        }
        .frame(minWidth: 960, minHeight: 760)
        .background(.regularMaterial)
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsManager.downloadStateDidChangeNotification)) { _ in
            downloadStateVersion += 1
        }
        .alert(loc("redownload_confirm_title"), isPresented: $showRedownloadAlert) {
            Button(loc("cancel"), role: .cancel) { }
            Button(loc("redownload_confirm_ok"), role: .destructive) { downloadModel() }
        } message: {
            Text(loc("redownload_confirm_msg"))
        }
        .sheet(isPresented: $showSherpaOnnxTest) {
            SherpaOnnxTestView()
        }
    }

    // MARK: - Helpers

    private var algoParamsCard: some View {
        @Bindable var settings = settings
        
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(loc("algo_params"), systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                PressableButton(disabled: false, action: resetAlgoDefaults) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text(loc("reset_defaults"))
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 120, maxWidth: 120)
                    .background(Color.orange.opacity(0.12))
                    .foregroundStyle(.orange)
                    .cornerRadius(6)
                }
            }
            
            Text(loc("algo_params_desc"))
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // ---- 音频处理 ----
            algoSectionHeader(loc("audio_processing"), "waveform")
            
            LazyVGrid(columns: algoColumns, spacing: 10) {
                algoCell(loc("silence_threshold"), value: $settings.silenceThreshold,
                         range: 0.0...0.1, fmt: "%.4f",
                         hintLow: loc("hint_more_precise"), hintHigh: loc("hint_more_lenient"))
                algoCell(loc("noise_gate"), value: $settings.noiseGate,
                         range: 0.0...0.01, fmt: "%.4f",
                         hintLow: loc("hint_more_precise"), hintHigh: loc("hint_more_lenient"))
                algoCell(loc("target_peak"), value: $settings.targetPeak,
                         range: 0.3...0.95, fmt: "%.2f",
                         hintLow: loc("hint_quieter"), hintHigh: loc("hint_louder"))
                algoCell(loc("base_gain"), value: $settings.baseGain,
                         range: 1.0...5.0, fmt: "%.1f", unit: loc("unit_times"),
                         hintLow: loc("hint_lower"), hintHigh: loc("hint_higher"))
            }
            
            // ---- 语音分段与转写 ----
            algoSectionHeader(loc("voice_segmentation"), "text.bubble")
            
            LazyVGrid(columns: algoColumns, spacing: 10) {
                algoCell(loc("pause_window"), value: $settings.pauseWindow,
                         range: 0.5...5.0, fmt: "%.1f", unit: loc("unit_seconds"),
                         hintLow: loc("hint_shorter"), hintHigh: loc("hint_longer"))
                algoCell(loc("max_chunk_duration"), value: $settings.maxChunkDuration,
                         range: 3.0...20.0, fmt: "%.0f", unit: loc("unit_seconds"),
                         hintLow: loc("hint_shorter"), hintHigh: loc("hint_longer"))
                algoCell(loc("min_duration_on"), value: $settings.minDurationOn,
                         range: 0.1...2.0, fmt: "%.1f",
                         hintLow: loc("hint_more_sensitive"), hintHigh: loc("hint_more_stable"))
                algoCell(loc("min_duration_off"), value: $settings.minDurationOff,
                         range: 0.1...2.0, fmt: "%.1f",
                         hintLow: loc("hint_finer_grained"), hintHigh: loc("hint_more_relaxed"))
                algoCell(loc("live_transcribe_interval"), value: $settings.liveTranscribeInterval,
                         range: 0.5...5.0, fmt: "%.1f", unit: loc("unit_seconds"),
                         hintLow: loc("hint_shorter"), hintHigh: loc("hint_longer"))
                algoCell(loc("consumer_poll_interval"), value: $settings.consumerPollInterval,
                         range: 0.1...1.0, fmt: "%.2f", unit: loc("unit_seconds"),
                         hintLow: loc("hint_shorter"), hintHigh: loc("hint_longer"))
            }
            
            // ---- 声纹处理 ----
            algoSectionHeader(loc("speaker_recognition"), "person.2.wave.2")
            
            LazyVGrid(columns: algoColumns, spacing: 10) {
                algoCell(loc("clustering_threshold"), value: $settings.clusteringThreshold,
                         range: 0.5...1.5, fmt: "%.2f",
                         hintLow: loc("hint_more_speakers"), hintHigh: loc("hint_fewer_speakers"))
                algoCell(loc("incremental_clustering_distance"), value: $settings.incrementalClusteringDistance,
                         range: 0.1...0.5, fmt: "%.2f",
                         hintLow: loc("hint_more_speakers"), hintHigh: loc("hint_fewer_speakers"))
                algoCell(loc("cluster_merge_distance"), value: $settings.clusterMergeDistance,
                         range: 0.3...0.7, fmt: "%.2f",
                         hintLow: loc("hint_more_speakers"), hintHigh: loc("hint_fewer_speakers"))
                algoCell(loc("matching_threshold"), value: $settings.matchingThreshold,
                         range: 0.3...0.9, fmt: "%.3f",
                         hintLow: loc("hint_more_tolerant"), hintHigh: loc("hint_more_strict"))
                algoCell(loc("high_confidence_threshold"), value: $settings.highConfidenceThreshold,
                         range: 0.5...0.95, fmt: "%.3f",
                         hintLow: loc("hint_more_lenient"), hintHigh: loc("hint_more_precise"))
                algoCell(loc("live_matching_threshold"), value: $settings.liveMatchingThreshold,
                         range: 0.3...0.8, fmt: "%.3f",
                         hintLow: loc("hint_more_tolerant"), hintHigh: loc("hint_more_strict"))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    
    private let algoColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    private func algoCell<V: BinaryFloatingPoint & LosslessStringConvertible>(
        _ label: String,
        value: Binding<V>, range: ClosedRange<V>, fmt: String, unit: String = "",
        hintLow: String = "", hintHigh: String = ""
    ) -> some View where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                let displayValue = Double(value.wrappedValue)
                Text("\(String(format: fmt, displayValue))\(unit)")
                    .font(.caption)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
            if !hintLow.isEmpty || !hintHigh.isEmpty {
                HStack {
                    Text(hintLow).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(hintHigh).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
    
    private func algoSectionHeader(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
    
    private func resetAlgoDefaults() {
        settings.silenceThreshold = 0.02
        settings.pauseWindow = 1.0
        settings.liveTranscribeInterval = 1.5
        settings.noiseGate = 0.002
        settings.targetPeak = 0.7
        settings.baseGain = 1.5
        settings.clusteringThreshold = 0.90
        settings.incrementalClusteringDistance = 0.28
        settings.clusterMergeDistance = 0.30
        settings.minDurationOn = 0.5
        settings.minDurationOff = 0.5
        settings.matchingThreshold = 0.70
        settings.highConfidenceThreshold = 0.75
        settings.liveMatchingThreshold = 0.70
        settings.consumerPollInterval = 0.3
        settings.maxChunkDuration = 8.0
    }

    // MARK: - Helpers (Model)

    /// 模型实际存储目录
    private var modelRepoPath: String {
        URL(fileURLWithPath: settings.modelPath)
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml").path
    }
    
    private var isModelDownloaded: Bool {
        let voice = settings.selectedVoice
        // 正在下载的模型不算已下载，避免下载中误判为已完成
        let state = settings.downloadState(for: voice)
        if state.isDownloading { return false }
        let id = SettingsManager.supportedModelID
        let repoPath = modelRepoPath
        let modelURL = URL(fileURLWithPath: repoPath).appendingPathComponent(id)
        
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            let markerURL = modelURL.appendingPathComponent(".download_complete")
            return FileManager.default.fileExists(atPath: markerURL.path)
        }
        return false
    }
    
    private func downloadModel() {
        let downloadingVoice = settings.selectedVoice
        let variant = SettingsManager.supportedModelID
        
        settings.setDownloadState(SettingsManager.ModelDownloadState(isDownloading: true, progress: 0.0, error: nil), for: downloadingVoice)

        downloadTask = Task {
            let downloadURL = URL(fileURLWithPath: settings.modelPath)
            
            do {
                let modelDir = try await ModelDownloadService.download(
                    variant: variant,
                    downloadBase: downloadURL
                ) { progress in
                    DispatchQueue.main.async {
                        var state = settings.downloadState(for: downloadingVoice)
                        state.progress = progress
                        settings.setDownloadState(state, for: downloadingVoice)
                    }
                }
                guard !Task.isCancelled else {
                    // 下载中途被取消：重置状态，清理标记文件
                    DispatchQueue.main.async {
                        var resetState = SettingsManager.ModelDownloadState()
                        settings.setDownloadState(resetState, for: downloadingVoice)
                        self.downloadTask = nil
                    }
                    // 清理可能存在的下载完成标记
                    let markerURL = modelDir.appendingPathComponent(".download_complete")
                    try? FileManager.default.removeItem(at: markerURL)
                    return
                }
                await WhisperService.shared.reset()
                try? Data().write(to: modelDir.appendingPathComponent(".download_complete"))
                DispatchQueue.main.async {
                    self.downloadTask = nil
                    var finalState = SettingsManager.ModelDownloadState()
                    finalState.isDownloaded = true
                    settings.setDownloadState(finalState, for: downloadingVoice)
                    settings.modelVersion = SettingsManager.supportedModelID
                    settings.save()
                }
            } catch {
                DispatchQueue.main.async {
                    if Task.isCancelled {
                        // 用户取消：重置为干净状态
                        var resetState = SettingsManager.ModelDownloadState()
                        settings.setDownloadState(resetState, for: downloadingVoice)
                    } else {
                        AppLog.error("hf-mirror download failed: \(error.localizedDescription)")
                        settings.setDownloadState(SettingsManager.ModelDownloadState(isDownloading: false, progress: 0.0, error: "\(loc("err_download_failed"))\n\(error.localizedDescription)"), for: downloadingVoice)
                    }
                    self.downloadTask = nil
                }
            }
        }
    }
    
    // MARK: - Helpers (Path)

    /// 加载设置并检测已下载模型版本
    private func load() {
        settings.load()
        // 检测已下载的模型版本
        let variant = SettingsManager.supportedModelID
        let modelURL = URL(fileURLWithPath: modelRepoPath).appendingPathComponent(variant)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir), isDir.boolValue {
            settings.modelVersion = variant
        }
    }
    
}

// MARK: - 可交互按钮（替代 macOS 上 Button 点击区域受限问题，同时保留视觉反馈）

private struct PressableButton<Label: View>: View {
    let disabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false

    var body: some View {
        label()
            .opacity(disabled ? 0.5 : (isPressed ? 0.7 : 1.0))
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .onHover { hovering in
                if hovering && !disabled {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture {
                guard !disabled else { return }
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isPressed = false
                }
                action()
            }
    }
}
