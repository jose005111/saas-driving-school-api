import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { ValidationPipe } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  await app.listen(process.env.PORT ?? 3000);

  // 1. CORS
  app.enableCors({
    origin: '*',
    methods: ['POST', 'GET', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'x-api-key'],
  });

  // 2. Prefixo global da API

  app.setGlobalPrefix('api');

  // 3. Validação Global
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  // 4. Swagger
  const config = new DocumentBuilder()
    .setTitle('Saas Driving School API')
    .setDescription(
      'Documentar a minha API para o meu SaaS de escola de condução',
    )
    .setVersion('1.0')
    .build();

  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('api/docs', app, document);

  // 5. Iniciar Servidor
  const port = process.env.PORT || 3000;
  await app.listen(port as any);

  console.log(`API Listening on port ${port}`);
  console.log(`Swagger run on ${await app.getUrl()}/api/docs`);
}
bootstrap();
