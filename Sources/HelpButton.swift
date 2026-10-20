import SwiftUI
struct HelpButton<Content:View>:View {
    let title:String
    let content:Content
    @State private var presented=false
    init(_ title:String,@ViewBuilder content:()->Content){self.title=title;self.content=content()}
    var body:some View {
        Button(title+"…"){presented=true}
            .sheet(isPresented:$presented){
                VStack(alignment:.leading,spacing:16){
                    HStack{Text(title).font(.title2.bold());Spacer();Button("Gereed"){presented=false}.keyboardShortcut(.cancelAction)}
                    Divider()
                    ScrollView{VStack(alignment:.leading,spacing:14){content}.font(.system(size:13)).lineSpacing(3).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}
                }.padding(24).frame(width:620,height:500)
            }
    }
}
