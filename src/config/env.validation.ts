import z from 'zod';

const envSchema = z.object({
  // === Validação das variaveis da aplicação ===
  NODE_ENV: z
    .enum(['development', 'production', 'test'])
    .default('development'),
  PORT: z.coerce.number().default(3000),
  CORS_ORIGINS: z.string().optional(),
  API_KEY: z.string().min(16),
  JWT_SECRET: z.string().min(32),
  JWT_EXPIRE_IN: z.string().default('1d'),

  // === Validação das variáveis do Banco  ===
  DB_HOST: z.string(),
  DB_PORT: z.coerce.number().default(5432),
  DB_USERNAME: z.string(),
  DB_PASSWORD: z.string(),
  DB_NAME: z.string(),
  DB_SSL: z.coerce.boolean().default(true).optional(),

  // Variáveis de Armazenamento

  // STORAGE_ENPOINT: z.string().url(),
  // STORAGE_BUCKET: z.string(),
  // STORAGE_ACCESS_KEY: z.string(),
  // STORAGE_SECRET_KEY: z.string(),
  // STORAGE_PUBLIC_URL: z.string().url(),
});

export type Env = z.infer<typeof envSchema>;

export function validateEnv(raw: Record<string, unknown>): Env {
  const result = envSchema.safeParse(raw);
  if (!result.success) {
    const issues = result?.error?.issues
      .map((i) => ` - ${i.path.join('.')}:     ${i.message}`)
      .join('\n');

    throw new Error(`Variáveis de ambiente com errros:\n ${issues} `);
  }

  return result?.data;
}
