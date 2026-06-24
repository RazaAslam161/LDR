import { type NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";

export async function middleware(request: NextRequest) {
  return await updateSession(request);
}

export const config = {
  matcher: [
    /*
     * Match all paths except:
     * - _next/static, _next/image, favicon (static assets)
     * - any file with an extension (.png, .svg, etc.)
     */
    "/((?!_next/static|_next/image|favicon.ico|.*\\.).*)",
  ],
};
