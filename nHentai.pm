# 替換從 "建立安全的檔名" 到最後的所有代碼

    # 建立安全的檔名
    my $safe_filename = "nhentai_$media_id";
    
    # 使用 LANraragi 的臨時檔案機制
    use File::Temp qw(tempfile);
    use File::Copy qw(move);
    
    my ($fh, $temp_zip) = tempfile(
        "nh_${media_id}_XXXXX",
        SUFFIX => '.zip',
        DIR    => $lrr_info->{tempdir},
        UNLINK => 0  # 不要自動刪除
    );
    close $fh;  # 關閉檔案控制碼，讓 Archive::Zip 可以寫入
    
    my $zip = Archive::Zip->new();
    
    $logger->info("Packaging images into $temp_zip using Archive::Zip...");
    
    my $added_count = 0;
    for (my $i = 1; $i <= $num_pages; $i++) {
        my $img_file = sprintf("%03d.%s", $i, $ext);
        my $img_full_path = "$work_dir/$img_file";
        if (-e $img_full_path && -s $img_full_path) {
            my $member = $zip->addFile($img_full_path, $img_file);
            if ($member) {
                $member->desiredCompressionMethod(COMPRESSION_STORED);
                $added_count++;
            }
        }
    }

    $logger->info("Added $added_count files to archive");

    if ($added_count == 0) {
        unlink $temp_zip;
        return ( error => "No valid files to add to archive." );
    }
    
    my $write_status = $zip->writeToFileNamed($temp_zip);
    unless ($write_status == AZ_OK) {
        $logger->error("Archive::Zip failed to write (status: $write_status)");
        unlink $temp_zip;
        return ( error => "ZIP packaging failed." );
    }
    
    # 驗證 ZIP 檔案
    unless (-e $temp_zip && -s $temp_zip > 0) {
        $logger->error("ZIP file is invalid: $temp_zip");
        unlink $temp_zip;
        return ( error => "ZIP file creation failed." );
    }

    my $zip_size = -s $temp_zip;
    $logger->info("ZIP created successfully: $temp_zip (size: $zip_size bytes)");
    
    # 清理工作目錄
    opendir(my $dh, $work_dir) or warn "Cannot open $work_dir: $!";
    while (my $file = readdir($dh)) {
        next if $file =~ /^\./;
        unlink "$work_dir/$file";
    }
    closedir($dh);
    rmdir $work_dir;
    
    # 返回給 LANraragi - 使用絕對路徑
    use Cwd 'abs_path';
    my $abs_path = abs_path($temp_zip);
    
    $logger->info("Returning file: $abs_path");
    
    return ( 
        file_path => $abs_path,
        filename  => "$safe_filename.zip",
        title     => $title || "nHentai $media_id"
    );
}

1;