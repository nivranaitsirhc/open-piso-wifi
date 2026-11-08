import { NextRequest, NextResponse } from 'next/server';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { getGatewayCapabilities } from '@/lib/daemon';

const execAsync = promisify(exec);

export const dynamic = 'force-dynamic';

export async function POST(request: NextRequest) {
  try {
    const capabilities = await getGatewayCapabilities();
    if (capabilities.gatewayType === 'local_linux') {
      return NextResponse.json({ error: 'OpenWrt deployment is unavailable in local Linux gateway mode.' }, { status: 409 });
    }

    const rootDir = path.resolve(process.cwd(), '..');
    const deployScript = path.join(rootDir, 'scripts', 'deploy-router.sh');

    if (process.platform !== 'linux') {
      return NextResponse.json({
        success: true,
        message: 'OpenWrt router deployment simulated in development environment.',
      });
    }

    const { stdout, stderr } = await execAsync(`bash ${deployScript}`, {
      cwd: rootDir,
      timeout: 30000,
    });

    return NextResponse.json({
      success: true,
      message: 'OpenWrt router configuration & firewall successfully deployed!',
      stdout: stdout.trim(),
      stderr: stderr.trim(),
    });
  } catch (error: any) {
    return NextResponse.json(
      {
        error: error.message || 'Router deployment failed. Please check network connection to 192.168.1.1.',
        stderr: error.stderr,
      },
      { status: 500 }
    );
  }
}
