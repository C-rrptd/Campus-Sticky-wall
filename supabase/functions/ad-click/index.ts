// Edge Function entry point. Logic lives in handler.ts (imported by tests).
import { serve } from "../_shared/auth.ts";
import { handler } from "./handler.ts";

serve(handler);
