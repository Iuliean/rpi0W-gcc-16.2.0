readonly TARGET=arm-linux-gnueabihf
readonly ARCH=armv6
readonly FPU=vfp

readonly BINUTILS=binutils-2.47
readonly GLIBC=glibc-2.36
readonly GCC=gcc-16.2.0
readonly LINUX_GIT=https\:\/\/github.com\/raspberrypi\/linux.git
readonly LINUX_BRANCH=rpi-6.18.y
readonly GNU_MIRROR=https\:\/\/ftp.gnu.org\/gnu\/

readonly ARCHIVES_PATH=$(pwd)/archives
readonly BUILD_PATH=$(pwd)/build-cross
readonly BUILD_NATIVE_PATH=$(pwd)/build-native
readonly LOG_DIR=$(pwd)/logs
readonly TOOLCHAIN_DIR=$(pwd)/$TARGET-$GCC
readonly TOOLCHAIN_NATIVE_DIR=$(pwd)/$TARGET-$GCC-native
readonly SYSROOT=$TOOLCHAIN_DIR/$TARGET/sysroot


readonly KERNEL=$(pwd)/linux

print_separator(){
	printf "\n\n\n---------------------------------------------------------------------------------------------------\n\n\n"
}

extract(){
	if [ ! -d "${1%.tar.xz}" ]; then
		echo "Extracting $ARCHIVES_PATH/$1..."
		tar xf $ARCHIVES_PATH/$1
		echo "Extracting $ARCHIVES_PATH/$1... done"
	fi
}

extract_all_components(){
	pushd $1

	if [[ ! -d $BINUTILS ]]; then
		extract $BINUTILS.tar.xz
	fi

	if [[ ! -d $GLIBC ]]; then
		extract $GLIBC.tar.xz
	fi

	if [[ ! -d $GCC ]]; then
		extract $GCC.tar.xz
	fi

	popd
}

download_component(){
	DOWNLOAD_LINK=$GNU_MIRROR$1.tar.xz
	echo "Downloading $DOWNLOAD_LINK..."
	pushd $ARCHIVES_PATH

	wget --quiet $DOWNLOAD_LINK

	popd
	echo "Downloading $DOWNLOAD_LINK...DONE"
}

install_linux_headers(){
	echo "Building linux headers..."

	make -C $KERNEL headers_install ARCH=arm INSTALL_HDR_PATH=$SYSROOT/usr 2>&1 > $LOG_DIR/linux-install-headers.log

	echo "Building linux header...done"
}

install_binutils(){
	echo "Installing binutils..."

	pushd $BUILD_PATH/$BINUTILS
	./configure \
		--target=$TARGET \
		--prefix=/ \
		--with-arch=$ARCH \
		--with-sysroot=/$TARGET/sysroot \
		--with-build-sysroot=$SYSROOT \
		--with-fpu=$FPU \
		--with-float=hard \
		--disable-multilib \
        2>&1 > $LOG_DIR/$BINUTILS-config.log

	make -j12 2>&1 > $LOG_DIR/$BINUTILS-build.log
	make install-strip DESTDIR=$TOOLCHAIN_DIR 2>&1 > $LOG_DIR/$BINUTILS-install.log

	popd
	echo "Installing binutils...done"
}

install_stage1_gcc(){
	echo "Installing gcc..."

	pushd $BUILD_PATH/$GCC
	
    mkdir build
	cd build

	../configure \
	--prefix=/ \
	--target=$TARGET \
	--enable-languages=c,c++ \
	--with-sysroot=/$TARGET/sysroot \
	--with-build-sysroot=$SYSROOT \
	--with-arch=$ARCH \
	--with-fpu=$FPU \
	--disable-libatomic \
	--with-float=hard \
    --disable-nls \
	--disable-multilib 2>&1 > $LOG_DIR/$GCC-configure.log

	make all-gcc -j12 2>&1 > $LOG_DIR/$GCC-build.log
	make install-strip-gcc DESTDIR=$TOOLCHAIN_DIR 2>&1 > $LOG_DIR/$GCC-install.log

    popd
	echo "Installing gcc...done"
}

install_glibc_headers(){
	echo "Install glibc headers..."
	
	pushd $BUILD_PATH/$GLIBC
	mkdir build
	cd build

    CC=$TOOLCHAIN_DIR/bin/$TARGET-gcc \
    CXX=$TOOLCHAIN_DIR/bin/$TARGET-g++ \
	../configure \
		--prefix=/usr \
		--build="$MACHTYPE" \
		--host=$TARGET \
		--target=$TARGET \
		--with-arch=$ARCH \
		--with-sysroot=/$TARGET/sysroot \
		--with-build-sysroot=$SYSROOT \
		--with-headers=$SYSROOT/usr/include \
		--with-lib=$SYSROOT/usr/lib \
		--with-fpu=$FPU \
		--with-float=hard \
		--disable-multilib \
		--disable-werror \
		libc_cv_forced_unwind=yes 2>&1 > $LOG_DIR/$GLIBC-bootstrap-headers-configure.log

	make -s install-bootstrap-headers=yes install-headers DESTDIR="$SYSROOT"


	make -s -j$(nproc) csu/subdir_lib 
	mkdir -p $SYSROOT/usr/lib
	
	install csu/crt1.o csu/crti.o csu/crtn.o "$SYSROOT"/usr/lib
	$TOOLCHAIN_DIR/bin/$TARGET-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o "$SYSROOT"/usr/lib/libc.so
	touch "$SYSROOT"/usr/include/gnu/stubs.h "$SYSROOT"/usr/include/bits/stdio_lim.h
	
    popd
	echo "Install glibc headers...done"
}

install_libgcc(){
	pushd $BUILD_PATH/$GCC/build

	make -s -j$(nproc) all-target-libgcc 2>&1 > $LOG_DIR/libgcc-all-target.log
	make -s install-target-libgcc DESTDIR="$TOOLCHAIN_DIR" 2>&1 > $LOG_DIR/libgcc-install-target.log

	popd
}


install_glibc(){
	pushd $BUILD_PATH/$GLIBC/build

	make -s -j$(nproc)
	make install DESTDIR=$SYSROOT
	
    popd
}

build_cross_toolchain(){
	mkdir -p $SYSROOT

	print_separator
	extract_all_components $BUILD_PATH

	print_separator
	install_linux_headers

	print_separator
	install_binutils

	print_separator
	install_stage1_gcc

	print_separator
	install_glibc_headers

	print_separator
	install_libgcc
	
	print_separator
	install_glibc

	pushd $BUILD_PATH/$GCC
	rm -rf build

	mkdir build
	cd build

	clear
	echo "Building final GCC...."
	sleep 5


	../configure --prefix= --target=$TARGET --enable-languages=c,c++ --with-sysroot=/$TARGET/sysroot --with-build-sysroot=$SYSROOT --with-headers=$SYSROOT/usr/include --with-lib=$SYSROOT/usr/lib --with-arch=$ARCH --with-fpu=$FPU --with-float=hard --disable-multilib
	make -s -j$(nproc)
	make -s install-strip DESTDIR="$TOOLCHAIN_DIR"
	popd
}

build_native_toolchain(){
	pushd $BUILD_NATIVE_PATH
	extract_all_components $BUILD_NATIVE_PATH

	pushd $GCC
		./contrib/download_prerequisites
		mkdir build
		cd build
		
		CC=$TOOLCHAIN_DIR/bin/$TARGET-gcc \
    	CXX=$TOOLCHAIN_DIR/bin/$TARGET-g++ \
		LD=$TOOLCHAIN_DIR/bin/$TARGET-gcc \
		../configure --build="$MACHTYPE" --host=$TARGET --target=$TARGET --enable-languages=c,c++ --with-arch=$ARCH --with-fpu=$FPU --with-float=hard --disable-multilib
		make -s -j$(nproc)
		make install-strip DESTDIR="$TOOLCHAIN_NATIVE_DIR"
	popd
}


if [[ $1 == "purge" ]]; then
	rm -rf $ARCHIVES_PATH $LOG_DIR $BUILD_PATH $TOOLCHAIN_DIR $BUILD_NATIVE_PATH $TOOLCHAIN_NATIVE_DIR
	exit 0
fi

if [[ $1 == "clean" ]]; then
	rm -rf $BUILD_PATH $TOOLCHAIN_DIR $LOG_DIR
	exit 0
fi

PATH=$TOOLCHAIN_DIR/bin:$PATH

if [[ ! -d $LOG_DIR ]]; then
    mkdir -p $LOG_DIR
fi


if [[ ! -d $ARCHIVES_PATH ]]; then
	mkdir -p $ARCHIVES_PATH
fi

if [[ ! -d linux ]]; then
	git clone --depth=1 $LINUX_GIT -b $LINUX_BRANCH
fi

if [ ! -e $ARCHIVES_PATH/$GCC.tar.xz ]; then
	download_component gcc/$GCC/$GCC
else
	echo "$GCC present -> skip download"
fi

if [ ! -e $ARCHIVES_PATH/$GLIBC.tar.xz ]; then
	download_component glibc/$GLIBC
else
	echo "$GLIBC present -> skip download"
fi

if [ ! -e $ARCHIVES_PATH/$BINUTILS.tar.xz ]; then
	download_component binutils/$BINUTILS
else
	echo "$BINUTILS present -> skip download"
fi

if [[ ! -d $BUILD_PATH ]]; then
	mkdir $BUILD_PATH
fi

if [[ ! -d $BUILD_NATIVE_PATH ]]; then
	mkdir $BUILD_NATIVE_PATH
fi

if [[ $1 == "native" ]]; then
	build_native_toolchain
	exit 0
fi

if [[ $1 == "cross" ]]; then
	build_cross_toolchain
	exit 0
fi

build_cross_toolchain
build_native_toolchain
