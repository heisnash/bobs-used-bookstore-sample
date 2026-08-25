using Amazon.Rekognition;
using Amazon.S3;
using Amazon.SecretsManager.Model;
using Amazon.SecretsManager;
using Bookstore.Data;
using Bookstore.Domain.AdminUser;
using Microsoft.AspNetCore.Builder;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using System.Text.Json;
using System;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Authorization;
using Npgsql;

namespace Bookstore.Web.Startup
{
    public static class ServicesSetup
    {
        public static WebApplicationBuilder ConfigureServices(this WebApplicationBuilder builder)
        {
            builder.Services.AddControllersWithViews(x =>
            {
                x.Filters.Add(new AuthorizeFilter());
                x.Filters.Add(new AutoValidateAntiforgeryTokenAttribute());
            });

            builder.Services.AddDefaultAWSOptions(builder.Configuration.GetAWSOptions());
            builder.Services.AddAWSService<IAmazonS3>();
            builder.Services.AddAWSService<IAmazonRekognition>();

            var connString = GetDatabaseConnectionString(builder.Configuration);
            builder.Services.AddDbContext<ApplicationDbContext>(option => option.UseNpgsql(connString));
            builder.Services.AddSession();

            return builder;
        }

        // If we find a non-empty connection string in appsettings, use it, otherwise
        // attempt to build it from data in Secrets Manager
        private static string GetDatabaseConnectionString(ConfigurationManager configuration)
        {
            // The secret name is fixed (no indirection via Parameter Store needed for the
            // Aurora PostgreSQL target). The secret contains host, port, username, and password.
            const string DbSecretName = "atx-db-modernization-nx-bookstore-aurora-pg-target-eCVMMK";

            var connString = configuration.GetConnectionString("BookstoreDbDefaultConnection");
            if (!string.IsNullOrEmpty(connString))
            {
                Console.WriteLine("Using localdb connection string");
                return connString;
            }

            try
            {
                Console.WriteLine($"Reading db credentials from secret {DbSecretName}");

                IAmazonSecretsManager secretsManagerClient;
                var options = configuration.GetAWSOptions();
                if (options != null)
                {
                    // local "integrated" debug mode using credentials/region in appsettings
                    secretsManagerClient = options.CreateServiceClient<IAmazonSecretsManager>();
                }
                else
                {
                    // deployed mode using credentials/region inferred on host
                    secretsManagerClient = new AmazonSecretsManagerClient();
                }

                var response = secretsManagerClient.GetSecretValueAsync(new GetSecretValueRequest
                {
                    SecretId = DbSecretName
                }).Result;

                var dbSecrets = JsonSerializer.Deserialize<DbSecrets>(response.SecretString, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });

                var npgsqlBuilder = new NpgsqlConnectionStringBuilder
                {
                    Host = dbSecrets.Host,
                    Port = dbSecrets.Port,
                    Database = "postgres",
                    SearchPath = "bobsusedbookstore_dbo",
                    Username = dbSecrets.Username,
                    Password = dbSecrets.Password,
                    SslMode = SslMode.Require
                };

                connString = npgsqlBuilder.ConnectionString;
            }
            catch (AmazonSecretsManagerException e)
            {
                Console.WriteLine($"Failed to read secret {DbSecretName}, error {e.Message}, inner {e.InnerException?.Message}");
            }
            catch (JsonException e)
            {
                Console.WriteLine($"Failed to parse content for secret {DbSecretName}, error {e.Message}");
            }

            return connString;
        }
    }
}
