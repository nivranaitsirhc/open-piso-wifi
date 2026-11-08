import { NextResponse } from 'next/server';
import { getGatewayCapabilities } from '@/lib/daemon';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    return NextResponse.json(await getGatewayCapabilities());
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Hardware gateway capabilities unavailable' },
      { status: 503 },
    );
  }
}
