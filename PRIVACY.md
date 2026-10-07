# Privacy

Gentence Senerator has no accounts and no analytics.

**What leaves the phone**
- Your typed and spoken answers, as text, go to Anthropic's API for grading.
- Recordings of your voice go to Microsoft Azure Speech for pronunciation scoring.
- Both pass through our server (a Cloudflare Worker), which adds the API keys and forwards them. It keeps grading requests and results for up to three days, then deletes them.
- Your device's push token is kept until your feedback is ready, so you can be notified.

Anthropic and Microsoft handle that data under their own API terms.

**What stays on the phone**
Your progress, history and settings. Deleting the app deletes them.

**Contact**
simonlcherv@gmail.com
