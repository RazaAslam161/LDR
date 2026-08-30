/// The FAQ, as const data.
///
/// Same rule as the terms: not a WebView and not a URL. Help has to be
/// readable offline, and opening Chrome throws the user out of an app whose
/// launcher identity may be a cover. `docs/legal/faq.md` is the canonical
/// wording — edits land there first and are mirrored here, minus what only
/// makes sense in a browser (download links, the support-contact block).
library;

class FaqEntry {
  const FaqEntry(this.question, this.answer);

  final String question;
  final String answer;
}

class FaqSection {
  const FaqSection(this.title, this.entries);

  final String title;
  final List<FaqEntry> entries;
}

/// The one answer that genuinely differs by channel: a Play install updates
/// through Play, a direct-link install updates through the app itself.
/// [selfUpdate] is UpdateService.allowed — the same flag that decides whether
/// the app may install its own APK at all.
List<FaqSection> milesFaq({required bool selfUpdate}) => [
      const FaqSection('Getting started', [
        FaqEntry(
          'What is Miles?',
          'A private space for two people in a relationship — messages, '
              'calls, photos, shared memories and small daily rituals of '
              'closeness, built for couples who live apart. There is no feed, '
              'no followers, and no one else in it: every account is paired '
              'with exactly one partner.',
        ),
        FaqEntry(
          'How much does it cost?',
          'Nothing. No subscriptions, no ads, no in-app purchases.',
        ),
        FaqEntry(
          'How do I connect with my partner?',
          'One of you creates the couple, then shares the short invite code '
              'the app generates. The other enters that code (or opens the '
              'invite link) and you’re paired. Codes are single-use and '
              'expire after 24 hours — if one expires, just make a new one.',
        ),
        FaqEntry(
          'Can a third person join?',
          'No. A couple is exactly two accounts. A code for a couple that is '
              'already complete is refused.',
        ),
        FaqEntry(
          'Is there an age requirement?',
          'Yes — Miles is for adults, 18 and over.',
        ),
      ]),
      const FaqSection('Privacy', [
        FaqEntry(
          'Is everything end-to-end encrypted?',
          'No, and we would rather tell you plainly than imply otherwise. A '
              'small set of especially sensitive areas is end-to-end '
              'encrypted — the encryption happens on your phone and our '
              'servers store only ciphertext they cannot read: Memory '
              'Threads and the text of Wish Jar entries.\n\nThe Private Vault '
              'is not in that list, because it would be easy to assume '
              'otherwise. What guards the Vault is the PIN, the block on '
              'screenshots, and access rules that let nobody but you reach it '
              '— not even your partner. Its files and its notes are stored '
              'unencrypted.\n\nEverything else (chat, media, location, profile) is '
              'protected by strict access controls and encryption in transit '
              'and at rest, but is not end-to-end encrypted. The privacy '
              'policy (Settings → About) lists exactly which is which.',
        ),
        FaqEntry(
          'Can anyone else see what we share?',
          'Access rules on the server restrict every piece of couple content '
              'to the two of you. Nobody else’s account can fetch '
              'it.\n\nA few features do have to reach an outside service to '
              'work at all — GIF search, map tiles, and the video site behind '
              'a Watch Together link — so those requests leave the app. They '
              'carry the search term, the map area, or the link you pasted; '
              'never your messages. The privacy policy (Settings → About) '
              'names every such service.',
        ),
        FaqEntry(
          'What are covers?',
          'An optional layer of discretion. In Settings → Disguise → '
              '“How this app looks” you can pick a '
              'cover identity — the app then looks like an ordinary utility '
              '(a calculator, a notes app, a weather app…) on your '
              'launcher and opens on a convincing stand-in screen until you '
              'enter through a private gesture shown when you pick the '
              'cover.\n\nMiles installs under its own name and icon; a cover '
              'is something you choose to put on, and you can take it off any '
              'time.',
        ),
        FaqEntry(
          'If I turn on a cover, what still shows the real name?',
          'Android’s own Settings → Apps list shows the app’s '
              'real entry. A cover changes the launcher and the opening '
              'screen, not the operating system’s records — treat it as '
              'discretion, not invisibility.',
        ),
        FaqEntry(
          'Can I lock the app?',
          'Yes. “Biometric app lock” (Settings → Security) requires your '
              'fingerprint, face, or a PIN every time the app opens. There is '
              'also a panic gesture — shake the phone three times, or press '
              'volume-up and volume-down together — that drops the app '
              'straight back to its cover screen if someone picks up your '
              'phone.',
        ),
        FaqEntry(
          'Does my partner see my location?',
          'Only if sharing is on, and only at the precision set: off, '
              'city-level, or precise. A new account starts at off — but know '
              'how it gets switched on, because it is not a second tap. After '
              'the app explains the feature, granting Android’s location '
              'permission is taken as your answer: sharing turns on at '
              'precise if you gave precise access, city-level if you gave '
              'only approximate. That happens once per account on a phone; '
              'after that the setting is only ever what you choose in '
              'Settings.\n\nTurning it off deletes the last shared position — '
              'it doesn’t just stop updating. Sharing runs only while the app '
              'is open in front of you; Miles asks for no background location '
              'at all.',
        ),
        FaqEntry(
          'Who can see the cycle tracker?',
          'You always. Your partner only while “Share with…” is on in the '
              'cycle screen’s own settings — it starts on, and turning it off '
              'hides your logs from them on the server, not just in their '
              'app. What they see even then is a gentle heads-up, not your '
              'entries.',
        ),
      ]),
      const FaqSection('Messages and calls', [
        FaqEntry(
          'Are voice and video calls free?',
          'Yes. Calls travel over the internet, so they use your data plan '
              '(or Wi-Fi). Video calls use roughly the data of any other '
              'video-calling app.',
        ),
        FaqEntry(
          'Do calls go through your servers?',
          'Calls connect phone-to-phone whenever the network allows, '
              'encrypted in transit. When a direct connection isn’t '
              'possible, the encrypted stream is relayed — the relay passes '
              'the data along but cannot read it.',
        ),
        FaqEntry(
          'Why did a message not arrive instantly?',
          'Usually the other phone is asleep or offline; delivery resumes '
              'the moment it reconnects. If it persists, check that battery '
              'optimisation isn’t restricting Miles on either phone '
              '(Android Settings → Battery).',
        ),
      ]),
      FaqSection('Updates', [
        if (selfUpdate)
          const FaqEntry(
            'How do updates work?',
            'From inside the app: it checks for a new version when it starts '
                'and shows an update prompt — there’s also an “Update '
                'available” row in Settings. One tap downloads the update '
                '(currently the full app, roughly 220 MB, so Wi-Fi is kinder), '
                'verifies it against a cryptographic fingerprint, and hands it '
                'to Android’s installer. Your messages, photos and login '
                'survive updates.\n\nThe first time, Android asks you to allow '
                'installs from Miles — that’s its standard step for any '
                'app that updates outside the Play Store, and Android itself '
                'refuses any update not signed by the same key as the app you '
                'already have.',
          )
        else
          const FaqEntry(
            'How do updates work?',
            'Through the Play Store, like any app — automatically if you have '
                'auto-update enabled, or from the app’s Play Store page. '
                'Your messages, photos and login survive updates. Occasionally '
                'a version is required to keep working with the server; the '
                'app will tell you plainly when that happens.',
          ),
        const FaqEntry(
          'How do I know if I’m up to date?',
          'Settings → About shows your version and build number, and a '
              '“Latest” line reading either “up to date” or the newer build '
              'number.',
        ),
      ]),
      const FaqSection('Your account and your data', [
        FaqEntry(
          'Where is my data stored?',
          'On servers in the Asia-Pacific region (Mumbai). The privacy '
              'policy (Settings → About) details what is stored and for '
              'how long.',
        ),
        FaqEntry(
          'I forgot my password. Is my history gone?',
          'Your account is recoverable by email reset. Your encryption key is '
              'a separate matter: a copy of it is kept on the server sealed '
              'with your password, so a password you still remember reopens '
              'it — and a password you have forgotten does not, including '
              'after a reset.\n\nThat is what your partner’s phone is for. As '
              'long as either phone still has the app signed in, everything '
              'survives: the app walks you both through a short, one-time '
              'handover in which their phone re-seals the keys to yours '
              '(you’ll read a 6-digit code to them; it expires after 10 '
              'minutes).\n\nIf both phones lose the app and the password is '
              'gone too, end-to-end encrypted content is unrecoverable. The '
              'sealed copy on the server is not a spare key we can use — it '
              'opens only with your password.',
        ),
        FaqEntry(
          'I got a new phone. What do I do?',
          'Install Miles and sign in. Signing in with your password unseals '
              'your encryption key from the server copy, so the encrypted '
              'areas simply open; everything not end-to-end encrypted is '
              'there too. Only if that fails — a forgotten password, or no '
              'sealed copy yet — do you need the handover from your '
              'partner’s phone described above.',
        ),
        FaqEntry(
          'What happens if we break up?',
          'Either of you can end it: Settings → Partner → “Remove partner”. '
              'It takes one of you — the connection is cut for both, '
              'immediately, and neither needs the other’s agreement. Nothing '
              'is sent to the other person; they find out by opening the '
              'app.\n\nFrom that moment the shared history — messages, photos, '
              'videos, Closer content — is kept for 30 days and then '
              'permanently deleted. Within those 30 days it can still be '
              'brought back, but it takes both of you: one asks to reconnect '
              'and the other agrees. Neither of you can restore it alone, and '
              'once someone has declined a request that same person cannot ask '
              'again. Pairing again with a fresh code is not the same thing — '
              'that starts a new couple, and the old history is still erased '
              'on schedule.\n\nYour private vault is not part of that. It is '
              'sealed with a key derived from your own account, not from the '
              'two of you, so it survives a breakup untouched.\n\nDeleting '
              'your account is the faster route and the '
              'more thorough one: if your partner has already gone, it '
              'removes the shared history immediately and erases the stored '
              'media files with it.',
        ),
        FaqEntry(
          'How do I delete my account?',
          'Settings → Account → Delete account removes your '
              'account and everything recorded against it alone — a real '
              'deletion, not a deactivation. Shared conversation history is '
              'the one thing that can outlive it, and only while your partner '
              'still has their account. There is also a web page for doing it '
              'without reinstalling the app, linked from the privacy policy.',
        ),
        FaqEntry(
          'Can I be forced to show what’s in the app?',
          'The app can’t prevent coercion, but it avoids making things '
              'worse: privacy choices leave no tell-tale marks, and a paused '
              'or quiet feature looks the same as nothing happening. If '
              'you’re in a situation where an app could put you at '
              'risk, trust your judgement first.',
        ),
      ]),
      const FaqSection('Safety', [
        FaqEntry(
          'What if I need space from my partner inside the app?',
          '“Pause notifications” (Settings → Safety) stops this phone being '
              'interrupted — for an hour, eight hours, a day, or until you '
              'turn it back on. It does not announce itself: your partner is '
              'not told and nothing on their side shows it. Nothing is '
              'deleted, and you can still send.\n\nThe limits are worth '
              'knowing, because a safety feature that is oversold is worse '
              'than one that is described. Nudges and Reaches stop notifying '
              'you, and that part is enforced on the server, so it holds '
              'whether or not your phone is on. An incoming call is dropped '
              'rather than rung — but that is done by this phone, so the call '
              'notification itself can still appear, even though opening it '
              'neither rings nor connects. Messages are not affected: they '
              'arrive as usual and you see them when you open the app.',
        ),
        FaqEntry(
          'How do I report a problem or someone’s behaviour?',
          'Settings → Safety → “Report a problem”. It is also on the menu at '
              'the top of Chat, on the toolbar when you hold a message, and '
              'on the toolbar when you hold an item in the Gallery. Reports '
              'go to us, not to your partner: nothing in the app can read '
              'them back, including your partner’s account and your own.',
        ),
      ]),
    ];
