import { registerAs } from '@nestjs/config';

export default registerAs('database', () => ({
  type: 'postgres' as const,
  host: process.env.DB_HOST!,
  port: Number(process.env.DB_PORT ?? 5432),
  username: process.env.DB_USERNAME!,
  password: process.env.DB_PASSWORD!,
  database: process.env.DB_NAME,
  // ssl: {
  //   rejectUnauthorized: false,
  // },
  synchronize: false,
  extra: {
    max: 10, // máximo de ligações no pool
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  },
}));
