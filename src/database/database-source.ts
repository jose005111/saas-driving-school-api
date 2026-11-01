import { config } from 'dotenv';

config({ path: '.env.dev' });
import { databaseConfig } from '../config/index';
import { DataSource } from 'typeorm';
import { join } from 'path';

export default new DataSource({
  ...(databaseConfig() as object),
  entities: [join(__dirname, '..', '**', '*.entity.{ts,js}')],
  migrations: [join(__dirname, 'migrations', '*.{ts,js}')],
  migrationsTableName: 'migrations',
} as any);
