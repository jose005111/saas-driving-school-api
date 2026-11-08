// config/storage.config.ts
import { registerAs } from '@nestjs/config';

export default registerAs('storage', () => ({
  endpoint: process.env.STORAGE_ENDPOINT!,
  bucket: process.env.STORAGE_BUCKET!,
  accessKey: process.env.STORAGE_ACCESS_KEY!,
  secretKey: process.env.STORAGE_SECRET_KEY!,
  publicUrl: process.env.STORAGE_PUBLIC_URL!,
}));
