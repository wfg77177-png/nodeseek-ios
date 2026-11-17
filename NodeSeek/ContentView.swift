import SwiftUI
import WebKit

// MARK: - Main JS (document end, main frame only)
// Minimal: auto sign-in + toast + section navigation + back to top. Nothing else.
private let nsJS = """
(function(){
  function store(k,v){ try{ localStorage.setItem('ns_'+k, v); }catch(e){} }
  function read(k,d){ try{ var v=localStorage.getItem('ns_'+k); return v===null?d:v; }catch(e){ return d; } }
  function readJSON(k,d){ try{ var v=JSON.parse(read(k,'')); return (v===null||v===undefined)?d:v; }catch(e){ return d; } }

  function showToast(msg){
    var t=document.createElement('div');
    t.textContent=msg;
    t.style.cssText='position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,0.82);color:#fff;padding:10px 16px;border-radius:20px;font-size:14px;z-index:999999;pointer-events:none;';
    document.body.appendChild(t);
    setTimeout(function(){ t.remove(); }, 2600);
  }
  window.__nsToast = showToast;

  // Auto sign-in (once per day; skip while the Cloudflare challenge is showing)
  (function autoSignIn(){
    if (document.title.indexOf('Just a moment') !== -1) return;
    var today = new Date().toISOString().slice(0,10);
    if (read('signDate','') === today) return;
    fetch('/api/attendance?random=true', {method:'POST', credentials:'include',
      headers:{'Content-Type':'application/json'}, body:'{}'})
      .then(function(r){ if(r.ok){ store('signDate', today); } return r.text(); })
      .then(function(t){
        try{ var j=JSON.parse(t); if(j && j.message){ showToast(j.message); } }catch(e){}
      })
      .catch(function(){});
  })();

  // Section navigation: click the nav link whose text matches the section name
  window.__nsGoSection = function(name){
    var links = Array.prototype.slice.call(document.querySelectorAll('a'));
    var hit = links.find(function(a){
      var t=(a.textContent||'').trim();
      return t===name && a.getAttribute('href') && a.getAttribute('href').indexOf('/')===0;
    });
    if(hit){ hit.click(); return true; }
    return false;
  };

  // Back to top
  window.__nsTop = function(){ window.scrollTo({top:0, behavior:'smooth'}); };

  // In-site search (site search box; history in localStorage)
  window.__nsDoSearch=function(q){
    q=(q||'').trim(); if(!q) return false;
    var h=readJSON('searchHist', []);
    h=h.filter(function(x){ return x!==q; }); h.unshift(q); if(h.length>10) h=h.slice(0,10);
    store('searchHist', JSON.stringify(h));
    var sels=['input[type="search"]', 'input[placeholder*="搜索"]', 'form[action*="search"] input', 'input[name="q"]', 'input[name="keyword"]'];
    var input=null;
    for(var i=0;i<sels.length;i++){ input=document.querySelector(sels[i]); if(input) break; }
    if(input){
      var form=input.closest ? input.closest('form') : null;
      var setter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(input, q);
      input.dispatchEvent(new Event('input', {bubbles:true}));
      if(form){ form.submit(); }
      else { input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true})); }
      return true;
    }
    return false;
  };
  window.__nsSearchHist=function(){ return read('searchHist','[]'); };
})();
"""

// MARK: - Browser model (navigation + sign-in only)
final class BrowserModel: NSObject, ObservableObject {
    weak var webView: WKWebView?
    @Published var searchHistory: [String] = []

    let homeURL = URL(string: "https://www.nodeseek.com/")!
    let sections = ["日常","技术","情报","测评","交易","拼车","推广","生活","Dev","贴图","曝光","沙盒"]

    override init() {
        super.init()
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func reload() { webView?.reload() }
    func backToTop() {
        webView?.evaluateJavaScript("window.__nsTop && window.__nsTop();", completionHandler: nil)
    }
    func goSection(_ name: String) {
        webView?.evaluateJavaScript("window.__nsGoSection && window.__nsGoSection('\(name)');") { _, _ in }
    }
    func manualSignIn() {
        webView?.evaluateJavaScript("""
          fetch('/api/attendance?random=true',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:'{}'})
            .then(r=>r.text()).then(t=>{ try{var j=JSON.parse(t); window.__nsToast && window.__nsToast(j.message||'已签到');}catch(e){ window.__nsToast && window.__nsToast('已签到'); } })
            .catch(()=>{ window.__nsToast && window.__nsToast('签到失败，请检查登录'); });
        """, completionHandler: nil)
    }
    func jsEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
    func doSearch(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        webView?.evaluateJavaScript("window.__nsDoSearch && window.__nsDoSearch('\(jsEsc(query))');") { [weak self] result, _ in
            guard let self = self else { return }
            self.loadSearchHistory()
            if result as? Bool == true { return }
            var comps = URLComponents(string: "https://www.google.com/search")
            comps?.queryItems = [URLQueryItem(name: "q", value: "site:nodeseek.com " + query)]
            if let url = comps?.url { self.load(url) }
        }
    }
    func loadSearchHistory() {
        webView?.evaluateJavaScript("window.__nsSearchHist && window.__nsSearchHist();") { [weak self] result, _ in
            guard let self = self else { return }
            if let json = result as? String, let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                self.searchHistory = arr
            }
        }
    }
}

// MARK: - Content view
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showSections = false
    @State private var showSearch = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            BottomBar(model: model, showSections: $showSections, showSearch: $showSearch)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSections) { SectionSheet(model: model) }
        .sheet(isPresented: $showSearch) { SearchSheet(model: model) }
    }
}

// MARK: - WebView (persistent cookie store; eager load)
struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent store: repeat opens reuse the HTTP cache and the Cloudflare
        // clearance cookie, so the challenge is skipped. Never clear it.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let main = WKUserScript(source: nsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(main)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        // Links that open in a new window (target="_blank", e.g. search results
        // and second-level pages) would otherwise do nothing: WKWebView has no
        // second web view to hand them to. Load them in this same web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

// MARK: - Bottom bar (5 buttons only)
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showSections: Bool
    @Binding var showSearch: Bool

    var body: some View {
        HStack(spacing: 4) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true }
            BarButton(icon: "checkmark.seal", label: "签到") { model.manualSignIn() }
            BarButton(icon: "magnifyingglass", label: "搜索") { showSearch = true }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Section picker sheet
struct SectionSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.sections, id: \.self) { name in
                        Button {
                            model.goSection(name)
                            dismiss()
                        } label: {
                            Text(name)
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("分区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Search sheet (in-site search; history in localStorage)
struct SearchSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("搜索") {
                    HStack {
                        TextField("搜帖子、用户…", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { doSearch() }
                        Button("搜索") { doSearch() }
                    }
                    if !model.searchHistory.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(model.searchHistory, id: \.self) { q in
                                    Button(q) { searchText = q; model.doSearch(q); dismiss() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    Text("先走站内搜索框；站内没有搜索框时用 Google 站内搜索兜底。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { model.loadSearchHistory() }
        }
        .presentationDetents([.medium])
    }

    func doSearch() {
        model.doSearch(searchText)
        dismiss()
    }
}
