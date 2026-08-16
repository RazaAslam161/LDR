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
              'small set of especially sensitive areas — memory threads and '
              'fantasy-jar entries — is end-to-end encrypted: the encryption '
              'happens on your phone, and our servers store only ciphertext '
              'they cannot read.\n\nEverything else (chat, media, location, '
              'profile) is protected by strict access controls and encryption '
              'in transit and at rest, but is not end-to-end encrypted. The '
              'privacy policy (Settings → About) lists exactly which is '
              'which.',
        ),
        FaqEntry(
          'Can anyone else see what we share?',
          'Access rules on the server restrict every piece of couple content '
              'to the two of you. Nobody else’s account can fetch it.',
        ),
        FaqEntry(
          'What are covers?',
          'An optional layer of discretion. From Settings you can choose a '
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
          'Yes. App Lock (Settings → Security) requires your '
              'fingerprint, face, or a PIN every time the app opens. There is '
              'also a quick gesture that locks the app instantly if someone '
              'picks up your phone.',
        ),
        FaqEntry(
          'Does my partner see my location?',
          'Only if you turn sharing on, and only at the precision you '
              'choose: off, city-level, or precise. Turning it off deletes '
              'the last shared position — it doesn’t just stop updating.',
        ),
        FaqEntry(
          'Who can see the cycle tracker?',
          'Both partners in the couple, by design — it exists to help you '
              'care for each other. If you’d rather not share it, '
              'don’t enable it.',
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
          'Settings → About shows your version and a “Latest '
              'available” line telling you whether a newer one exists.',
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
          'Your account is recoverable by email reset. For the end-to-end '
              'encrypted areas, your phone holds the key — so as long as '
              'either phone still has the app signed in, everything '
              'survives: the app walks you and your partner through a short, '
              'one-time recovery in which their phone hands the keys back to '
              'yours (you’ll read a 6-digit code to them; it expires '
              'after 10 minutes).\n\nIf both phones lose the app and no '
              'backup applies, end-to-end encrypted content is unrecoverable '
              '— that is the honest cost of encryption nobody else holds '
              'keys to.',
        ),
        FaqEntry(
          'I got a new phone. What do I do?',
          'Install Miles, sign in, and follow the recovery step above so '
              'your new phone receives the encryption keys from your '
              'partner’s. Everything not end-to-end encrypted is simply '
              'there after signing in.',
        ),
        FaqEntry(
          'What happens if we break up?',
          'Either of you can leave the couple from Settings. When the second '
              'partner leaves (or an account is deleted), the couple’s '
              'entire history — messages, photos, videos, everything — is '
              'permanently deleted 30 days later, storage included. '
              'Re-pairing within those 30 days cancels the deletion.',
        ),
        FaqEntry(
          'How do I delete my account?',
          'Settings → Account → Delete account removes your '
              'account and your content — a real deletion, not a '
              'deactivation. There is also a web page for requesting '
              'deletion without reinstalling the app, linked from the '
              'privacy policy.',
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
          'Contact Pause (Settings) quiets calls and alerts from your '
              'partner without announcing itself. It’s enforced on the '
              'server, so it works even if your phone is off.',
        ),
        FaqEntry(
          'How do I report a problem or someone’s behaviour?',
          'Settings → Report. Reports go to us, not to your partner — '
              'include your app version (Settings → About) so we can '
              'help faster.',
        ),
      ]),
    ];
