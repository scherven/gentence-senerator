import SwiftUI

struct ContentView: View {
    @State private var selectedLanguage = "Mandarin"
    @State private var userTranslation = ""
    @State private var showFeedback = false
    @State private var feedbackText = ""
    @State private var englishSentence = "The boy carries the red box."
    @State private var isLoading = false
    @State private var apiKey = Key.key
    @State private var showAPIKeyInput = true
    
    let languages = ["Mandarin", "French", "German", "Spanish"]
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Language Learning")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 40)
            
            mainContentView
            
            Spacer()
        }
    }
    
    var mainContentView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // English sentence to translate
            VStack(spacing: 10) {
                Text("Translate this sentence:")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                if isLoading && englishSentence == "The boy carries the red box." {
                    ProgressView()
                        .padding()
                } else {
                    Text(englishSentence)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal)
            
            // Language picker
            VStack(alignment: .leading, spacing: 10) {
                Text("Target Language:")
                    .font(.headline)
                
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            .padding(.horizontal)
            
            // Text input field
            VStack(alignment: .leading, spacing: 10) {
                Text("Your translation:")
                    .font(.headline)
                
                TextField("Type your translation here...", text: $userTranslation)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.body)
                    .onSubmit {
                        checkTranslation()
                    }
                    .disabled(isLoading)
            }
            .padding(.horizontal)
            
            // Submit button
            HStack(spacing: 15) {
                Button(action: checkTranslation) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Submit")
                    }
                }
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(isLoading ? Color.gray : Color.blue)
                .cornerRadius(10)
                .disabled(isLoading || userTranslation.isEmpty)
                
                Button(action: generateNewSentence) {
                    Text("New Sentence")
                }
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .cornerRadius(10)
                .disabled(isLoading)
            }
            .padding(.horizontal)
            
            // Feedback area
            if showFeedback && !feedbackText.isEmpty {
                ScrollView {
                    Text(feedbackText)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                }
                .frame(maxHeight: 200)
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .onChange(of: selectedLanguage) { _ in
            showFeedback = false
            userTranslation = ""
            feedbackText = ""
        }
    }
    
    func generateNewSentence() {
        isLoading = true
        showFeedback = false
        feedbackText = ""
        userTranslation = ""
        
        let prompt = "Generate a simple English sentence suitable for language learning. It should be practical and useful for everyday conversation. Just provide the sentence, nothing else."
        
        callGPT(prompt: prompt) { response in
            DispatchQueue.main.async {
                self.englishSentence = response
                self.isLoading = false
            }
        }
    }
    
    func checkTranslation() {
        guard !userTranslation.isEmpty else { return }
        
        isLoading = true
        showFeedback = false
        
        let languageName = selectedLanguage
        let prompt = """
        The student is learning \(languageName). They were asked to translate this English sentence:
        "\(englishSentence)"
        
        Their translation in \(languageName) is:
        "\(userTranslation)"
        
        Please provide detailed feedback:
        1. Is the translation correct or incorrect?
        2. What's the correct translation?
        3. Explain any mistakes they made
        
        Be supportive and educational in your response.
        """
        
        callGPT(prompt: prompt) { response in
            DispatchQueue.main.async {
                self.feedbackText = response
                self.showFeedback = true
                self.isLoading = false
            }
        }
    }
    
    func callGPT(prompt: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion("Error: Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = [
            "model": "gpt-4",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion("Error: \(error.localizedDescription)")
                return
            }
            
            guard let data = data else {
                completion("Error: No data received")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    completion(content)
                } else {
                    completion("Error: Unexpected response format")
                }
            } catch {
                completion("Error: Failed to parse response")
            }
        }.resume()
    }
}

#Preview {
    ContentView()
}
