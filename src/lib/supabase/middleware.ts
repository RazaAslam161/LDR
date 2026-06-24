import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

/**
 * Refreshes the auth session on every matched request so Server Components
 * always see a fresh session. Standard Supabase + Next.js App Router pattern.
 */
export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { pathname } = request.nextUrl;
  const isAuthPage = pathname === "/login" || pathname === "/signup";
  const isOnboarding = pathname === "/welcome" || pathname === "/couple";
  const isProtected = pathname.startsWith("/app");

  // Not signed in + trying to reach app → send to login
  if (!user && isProtected) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("redirect", pathname);
    return NextResponse.redirect(url);
  }

  // Signed in + lingering on auth pages → push into the app
  if (user && isAuthPage) {
    const url = request.nextUrl.clone();
    url.pathname = "/app";
    url.search = "";
    return NextResponse.redirect(url);
  }

  // Signed in but no profile / couple yet → nudge to onboarding
  if (user && !isOnboarding && !isProtected) {
    const { data: profile } = await supabase
      .from("profiles")
      .select("id, couple_id")
      .eq("id", user.id)
      .maybeSingle();

    if (!profile) {
      const url = request.nextUrl.clone();
      url.pathname = "/welcome";
      url.search = "";
      return NextResponse.redirect(url);
    }
    if (!profile.couple_id) {
      const url = request.nextUrl.clone();
      url.pathname = "/couple";
      url.search = "";
      return NextResponse.redirect(url);
    }
  }

  return supabaseResponse;
}
