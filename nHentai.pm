package LANraragi::Plugin::Download::nHentai;

use strict;
use warnings;
no warnings 'uninitialized';

use LANraragi::Utils::Logging qw(get_plugin_logger);

sub plugin_info {
    return (
        name         => "nHentai Downloader",
        type         => "download",
        namespace    => "nhdl",
        author       => "Gemini CLI",
        version      => "1.0",
        description  => "Downloads galleries from nHentai using image scraping. Works best if cookies are set in the nHentai Metadata plugin.",
        url_regex    => 'https?:\/\/nhentai\.net\/g\/\d+\/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_;
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Download Triggered: $url ---");

    # 使用 LRR 預先配置好的 UserAgent (包含 Cookies 和自定義 UA)
    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);

    my $tx = $ua->get($url);
    my $res = $tx->result;

    if ($res->is_success) {
        my $html = $res->body;
        
        # 1. 提取 Media ID (這是抓圖的核心)
        # 尋找類似 /galleries/1234567/ 的字串
        if ($html =~ m|/galleries/(\d+)/|i) {
            my $media_id = $1;
            
            # 2. 提取總頁數
            my $num_pages = 0;
            if ($html =~ m|<span class="name">(\d+)</span>|i || $html =~ m|<div>(\d+) pages</div>|i) {
                $num_pages = $1;
            }

            if ($media_id && $num_pages > 0) {
                $logger->info("Found Media ID: $media_id, Pages: $num_pages");
                
                # 3. 偵測圖片格式 (通常第一張圖是什麼格式，後面就是什麼格式)
                my $ext = "jpg";
                if ($html =~ m|/galleries/$media_id/1\.(png|webp|jpg)|i) {
                    $ext = $1;
                }

                my @images;
                for (my $i = 1; $i <= $num_pages; $i++) {
                    # 構造 i.nhentai.net 的直連
                    push @images, "https://i.nhentai.net/galleries/$media_id/$i.$ext";
                }

                $logger->info("Successfully generated " . scalar @images . " image URLs.");
                return ( url_list => \@images );
            }
        }
    } else {
        $logger->error("Access failed: " . $res->code . " - " . $res->message);
        return ( error => "nHentai access failed. Check your cookies/UA or if you are blocked by Cloudflare." );
    }

    return ( error => "Could not parse nHentai page content." );
}

1;
