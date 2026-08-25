using Bookstore.Domain.Addresses;
using Bookstore.Domain.Books;
using Bookstore.Domain.Carts;
using Bookstore.Domain.Customers;
using Bookstore.Domain.Offers;
using Bookstore.Domain.Orders;
using Bookstore.Domain.ReferenceData;
using Microsoft.EntityFrameworkCore;

namespace Bookstore.Data
{
    public partial class ApplicationDbContext : DbContext
    {
        public ApplicationDbContext() { }

        public ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : base(options) { }

        public DbSet<Address> Address { get; set; }

        public DbSet<Book> Book { get; set; }

        public DbSet<Customer> Customer { get; set; }

        public DbSet<Order> Orders { get; set; }

        public DbSet<ShoppingCart> ShoppingCart { get; set; }

        public DbSet<ShoppingCartItem> ShoppingCartItem { get; set; }

        public DbSet<OrderItem> OrderItem { get; set; }

        public DbSet<Offer> Offer { get; set; }

        public DbSet<ReferenceDataItem> ReferenceData { get; set; }

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            // Set default schema so all tables resolve in bobsusedbookstore_dbo
            modelBuilder.HasDefaultSchema("bobsusedbookstore_dbo");

            // ── Address ──────────────────────────────────────────────────────────
            modelBuilder.Entity<Address>(e =>
            {
                e.ToTable("address");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.AddressLine1).HasColumnName("addressline1");
                e.Property(x => x.AddressLine2).HasColumnName("addressline2");
                e.Property(x => x.City).HasColumnName("city");
                e.Property(x => x.State).HasColumnName("state");
                e.Property(x => x.Country).HasColumnName("country");
                e.Property(x => x.ZipCode).HasColumnName("zipcode");
                e.Property(x => x.CustomerId).HasColumnName("customerid");
                e.Property(x => x.IsActive).HasColumnName("isactive");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
            });

            // ── Book ─────────────────────────────────────────────────────────────
            modelBuilder.Entity<Book>(e =>
            {
                e.ToTable("book");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.Name).HasColumnName("name");
                e.Property(x => x.Author).HasColumnName("author");
                e.Property(x => x.Year).HasColumnName("year");
                e.Property(x => x.ISBN).HasColumnName("isbn");
                e.Property(x => x.PublisherId).HasColumnName("publisherid");
                e.Property(x => x.BookTypeId).HasColumnName("booktypeid");
                e.Property(x => x.GenreId).HasColumnName("genreid");
                e.Property(x => x.ConditionId).HasColumnName("conditionid");
                e.Property(x => x.CoverImageUrl).HasColumnName("coverimageurl");
                e.Property(x => x.Summary).HasColumnName("summary");
                e.Property(x => x.Price).HasColumnName("price");
                e.Property(x => x.Quantity).HasColumnName("quantity");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
                e.HasOne(x => x.Publisher).WithMany().HasForeignKey(x => x.PublisherId).OnDelete(DeleteBehavior.Restrict);
                e.HasOne(x => x.BookType).WithMany().HasForeignKey(x => x.BookTypeId).OnDelete(DeleteBehavior.Restrict);
                e.HasOne(x => x.Genre).WithMany().HasForeignKey(x => x.GenreId).OnDelete(DeleteBehavior.Restrict);
                e.HasOne(x => x.Condition).WithMany().HasForeignKey(x => x.ConditionId).OnDelete(DeleteBehavior.Restrict);
            });

            // ── Customer ─────────────────────────────────────────────────────────
            modelBuilder.Entity<Customer>(e =>
            {
                e.ToTable("customer");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.Sub).HasColumnName("sub");
                e.Property(x => x.Username).HasColumnName("username");
                e.Property(x => x.FirstName).HasColumnName("firstname");
                e.Property(x => x.LastName).HasColumnName("lastname");
                e.Property(x => x.Email).HasColumnName("email");
                e.Property(x => x.DateOfBirth).HasColumnName("dateofbirth");
                e.Property(x => x.Phone).HasColumnName("phone");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
                e.HasIndex(x => x.Sub).IsUnique();
            });

            // ── Orders ───────────────────────────────────────────────────────────
            modelBuilder.Entity<Order>(e =>
            {
                e.ToTable("orders");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.CustomerId).HasColumnName("customerid");
                e.Property(x => x.AddressId).HasColumnName("addressid");
                e.Property(x => x.DeliveryDate).HasColumnName("deliverydate");
                e.Property(x => x.OrderStatus).HasColumnName("orderstatus");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
                e.HasOne(x => x.Customer).WithMany().OnDelete(DeleteBehavior.Restrict);
            });

            // ── OrderItem ────────────────────────────────────────────────────────
            modelBuilder.Entity<OrderItem>(e =>
            {
                e.ToTable("orderitem");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.OrderId).HasColumnName("orderid");
                e.Property(x => x.BookId).HasColumnName("bookid");
                e.Property(x => x.Quantity).HasColumnName("quantity");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
            });

            // ── ShoppingCart ─────────────────────────────────────────────────────
            modelBuilder.Entity<ShoppingCart>(e =>
            {
                e.ToTable("shoppingcart");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.CorrelationId).HasColumnName("correlationid");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
            });

            // ── ShoppingCartItem ─────────────────────────────────────────────────
            modelBuilder.Entity<ShoppingCartItem>(e =>
            {
                e.ToTable("shoppingcartitem");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.ShoppingCartId).HasColumnName("shoppingcartid");
                e.Property(x => x.BookId).HasColumnName("bookid");
                e.Property(x => x.Quantity).HasColumnName("quantity");
                e.Property(x => x.WantToBuy).HasColumnName("wanttobuy");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
            });

            // ── Offer ────────────────────────────────────────────────────────────
            modelBuilder.Entity<Offer>(e =>
            {
                e.ToTable("offer");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.Author).HasColumnName("author");
                e.Property(x => x.ISBN).HasColumnName("isbn");
                e.Property(x => x.BookName).HasColumnName("bookname");
                e.Property(x => x.FrontUrl).HasColumnName("fronturl");
                e.Property(x => x.GenreId).HasColumnName("genreid");
                e.Property(x => x.ConditionId).HasColumnName("conditionid");
                e.Property(x => x.PublisherId).HasColumnName("publisherid");
                e.Property(x => x.BookTypeId).HasColumnName("booktypeid");
                e.Property(x => x.Summary).HasColumnName("summary");
                e.Property(x => x.OfferStatus).HasColumnName("offerstatus");
                e.Property(x => x.Comment).HasColumnName("comment");
                e.Property(x => x.CustomerId).HasColumnName("customerid");
                e.Property(x => x.BookPrice).HasColumnName("bookprice");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
                e.HasOne(x => x.Publisher).WithMany().HasForeignKey(x => x.PublisherId).OnDelete(DeleteBehavior.Restrict);
                e.HasOne(x => x.BookType).WithMany().HasForeignKey(x => x.BookTypeId).OnDelete(DeleteBehavior.Restrict);
                e.HasOne(x => x.Genre).WithMany().HasForeignKey(x => x.GenreId).OnDelete(DeleteBehavior.Restrict);
                e.HasOne(x => x.Condition).WithMany().HasForeignKey(x => x.ConditionId).OnDelete(DeleteBehavior.Restrict);
            });

            // ── ReferenceData ────────────────────────────────────────────────────
            modelBuilder.Entity<ReferenceDataItem>(e =>
            {
                e.ToTable("referencedata");
                e.Property(x => x.Id).HasColumnName("id");
                e.Property(x => x.DataType).HasColumnName("datatype");
                e.Property(x => x.Text).HasColumnName("text");
                e.Property(x => x.CreatedBy).HasColumnName("createdby");
                e.Property(x => x.CreatedOn).HasColumnName("createdon");
                e.Property(x => x.UpdatedOn).HasColumnName("updatedon");
            });

            PopulateDatabase(modelBuilder);

            base.OnModelCreating(modelBuilder);
        }
    }
}
